#!/usr/bin/perl
# Container::Buildah
# ABSTRACT: Use 'buildah' to enter namespace of OCI/Docker-compatible container image while building it
# by Ian Kluft
package Container::Buildah;
use strict;
use warnings;
use autodie;
use Modern::Perl qw(2017); # oldest versions of Perl this will run on
use Carp qw(confess);
use Exporter;
use Getopt::Long;
use Data::Dumper;
use IO::Handle;
use FindBin;
use File::stat;
use File::Sync qw(sync);
use Algorithm::Dependency;
use Algorithm::Dependency::Source::HoA;
use YAML::XS;
use Template;

our $VERSION = '0.1.0';

use parent qw(Class::Singleton Exporter);

=pod

=head1 NAME

Container::Buildah - Use 'buildah' to enter namespace of OCI/Docker-compatible container image while building it

=head1 DESCRIPTION

B<Container::Buildah> allows Perl scripts to build OCI/Docker-compatible container images using the Open Source
I<buildah> command. Containers may be pipelined so the product of a build stage is consumed by one or more others.

The user of the B<Container::Buildah> module configures container build stages including a reference to a
callback function which will run inside the user namespace of the container in ordetr to build it.
The function is analagous to a Dockerfile, except that it's fully programmable as Perl code.

The I<buildah> command has subcommands equivalent to Dockerfile directives.
B<Container::Buildah> automatically adds the I<--add-history> option so that each action will be recorded
as part of the OCI container build history.

=cut

#
# initialize environment
#

# allow export of class functions
our @EXPORT_OK = qw(buildah);

# globals
$Container::Buildah::debug=0;
$Container::Buildah::template_config = {
	INTERPOLATE  => 1,
	POST_CHOMP   => 1,
	RECURSION    => 1,
	EVAL_PERL    => 0,
	PRE_CHOMP    => 2,
	POST_CHOMP   => 2,
};
$Container::Buildah::init_config = {};

# initialization on the singleton instance
# see parent Class::Singleton
sub _new_instance
{
	my $class = shift;
	my $self  = bless { }, $class;
	my %params = @_;

	if (exists $params{debug}) { print STDERR "debug: _new_instance: params=".Dumper(\%params); }

	# set up config hash - use yaml_config file if provided, then add all entries from config parameter
	# note: YAML is the preferred location to keep configuration that changes frequently such as software versions
	if (not exists $self->{config}) {
		$self->{config} = {};
	}
	if (exists $params{yaml_config}) {
		say STDERR "params: ".Dumper(\%params);
		my $in_config = YAML::XS::LoadFile($params{yaml_config});
		say STDERR "YAML: ".Dumper($in_config);
		if (ref $in_config eq "HASH") {
			$self->{config} = $in_config;
		} elsif (ref $in_config eq "ARRAY" and ref $in_config->[0] eq "HASH") {
			$self->{config} = $in_config->[0];
		} else {
			confess __PACKAGE__.": can't find associative array for configuration data";
		}
	}
	if (exists $params{config}) {
		foreach my $key (keys %{$params{config}}) {
			$self->{config}{$key} = $params{config}{$key};
		}
	}

	# process container basename for this instance
	if (exists $self->{config}{basename}) {
		# timestamp string for log file names
		# set environment for child processes, or use it if established by parent
		my $timestamp_envname = uc($self->{config}{basename}."_TIMESTAMP_STR");
		if (exists $ENV{$timestamp_envname}) {
			$self->{config}{timestamp_str} = $ENV{$timestamp_envname};
		} else {
			my @timestamp = localtime;
			$timestamp[4]++; # fix month from 0-base
			$timestamp[5] += 1900; # fix year from 1900 base
			$self->{config}{timestamp_str} = sprintf "%04d-%02d-%02d-%02d-%02d-%02d",
				$timestamp[5], $timestamp[4], $timestamp[3],
				$timestamp[2], $timestamp[1],$timestamp[0];
			$ENV{$timestamp_envname} = $self->{config}{timestamp_str};
		}
	} else {
		die __PACKAGE__.": required basename initialization parameter not found";
	}

	# Template setup
	$self->{template} = Template->new($Container::Buildah::template_config);

	# redirect STDIN from /dev/null so subprocesses run automated and can't prompt STDIN
	open STDIN, "<", "/dev/null" or die "failed to redirect STDIN";

	# save STDOUT and STDERR so they can be restored after redirects
	open($self->{oldstdout}, '>&STDOUT') or die "Can't dup STDOUT: $!";
	open($self->{oldstderr}, '>&STDERR') or die "Can't dup STDERR: $!";

	return $self;
}

# print debug messages
sub debug
{
	if ($Container::Buildah::debug) {
		say STDERR "debug: ".join(" ", @_);
		my $self = Container::Buildah->instance();
		if ($self->{oldstderr}->fileno != fileno(STDERR)) {
			$self->{oldstderr}->print("debug: ".join(" ", @_)."\n");
		}
	}
}

# template and variable expansion
sub expand
{
	my $value = shift;

	# process array values sequentially
	if (ref $value eq "ARRAY") {
		my @result;
		foreach my $subvalue (@$value) {
			push @result, Container::Buildah::expand($subvalue);
		}
		return \@result;
	}

	# process scalar value
	my $output;
	my $util = Container::Buildah->instance();
	$util->{template}->process(\$value, $util->{config}, \$output);
	debug "expand: $value -> $output";
	my $count=0;
	while ($output =~ /\[%.*%\]/ and $count++ < 10) {
		$value = $output;
		$output = ""; # clear because template concatenates to it
		$util->{template}->process(\$value, $util->{config}, \$output);
		debug "expand ($count): $value -> $output";
	}
	return $output;
}

# get configuration value
sub get_config
{
	my $class_or_obj = shift;
	my $self = (ref $class_or_obj) ? $class_or_obj : $class_or_obj->instance();
	my @path = @_;

	# special case for empty path: return config tree root
	if (not @path) {
		return $self->{config};
	}

	# navigate down config tree
	my $key = pop @path; # last entry of path is target node
	my $orig_path = join("/", @path)."->".$key; # for error reporting
	my $node = $self->{config};
	while (@path) {
		my $subnode = shift @path;
		if (exists $node->{$subnode} and ref $node->{$subnode} eq "HASH") {
			$node = $node->{$subnode};
		} else {
			confess "get_config: ($subnode) not found in search for $orig_path";
		}
	}

	# return configuration
	if (exists $node->{$key}) {
		if (ref $node->{$key} and ref $node->{$key} ne "ARRAY") {
			return $node->{$key};
		}

		# if the value is a scalar, perform variable expansion
		return Container::Buildah::expand($node->{$key});
	}
	return;
}

# allow caller to enforce its required configuration
sub required_config
{
	my $class_or_obj = shift;
	my $self = (ref $class_or_obj) ? $class_or_obj : $class_or_obj->instance();

	# check for missing config parameters required by program
	my @missing;
	foreach my $key (@_) {
		if (not exists $self->{config}{$key}) {
			push @missing, $key;
		}
	}

	# fail if any required parameters are missing
	if (@missing) {
		die __PACKAGE__.": required configuration parameters missing: ".join(" ", @missing);
	}
}

# set debug mode on or off
sub set_debug
{
	$Container::Buildah::debug = shift;
}

# get path to the executing script
# used for file dependency checks and re-running in containers
sub progpath
{
	state $progpath = "$FindBin::Bin/$FindBin::Script";
	return $progpath;
}

# get file modification timestamp
sub ftime
{
	my $file = shift;
	if (not  -f $file ) {
		return;
	}
	my $fstat = stat $file;
	return $fstat->mtime;
}

# check if this script is newer than a deliverable file, or if the deliverable doesn't exist
sub check_deliverable
{
	my $depfile = shift;
	if (not  -f $depfile) {
		return "does not exist";
	}
	if (ftime(progpath()) > ftime($depfile)) {
		return "program modified";
	}
	return;
}

# handle exceptions from eval blocks
sub exception_handler
{
	no autodie;
	my $xc = shift;
	if ($xc) {
		if (ref $xc eq "autodie::exception") {
			say STDERR "exception(".$xc->function."): ".$xc->eval_error." at ".$xc->file." line ".$xc->line;
		} elsif (ref $xc) {
			say STDERR "exception(".(ref $xc)."): ".$xc
		} else {
			say STDERR "exception: ".$xc;
		}
		my $self = Container::Buildah->instance();
		open(STDOUT, '>&', $self->{oldstdout});
		open(STDERR, '>&', $self->{oldstderr});

		# report status if possible and exit
		my $util = Container::Buildah->instance();
		my $basename = $util->{config}{basename} // "unnamed container";
		say STDERR $basename." failed";
		exit 1;
	}
}

# drop leading slash from a path
sub dropslash
{
	my $str = shift;
	if (substr($str,0,1) eq '/') {
		substr($str,0,1) = '';
	}
	return $str;
}

# run a command and report errors
sub cmd
{
	no autodie;
	my $opts = shift;
	my @args = @_;
	my $name = (exists $opts->{name}) ? $opts->{name} : "cmd";

	eval {
		debug "cmd $name ".join(" ", @args);
		system(@args);
		if ($? == -1) {
			confess "failed to execute command (".join(" ", @args)."): $!";
		} elsif ($? & 127) {
			confess sprintf "command (".join(" ", @args)." child died with signal %d, %s coredump\n",
				($? & 127),  ($? & 128) ? 'with' : 'without';
		} elsif ($? >> 8 != 0) {
			if (exists $opts->{nonzero} and ref $opts->{nonzero} eq "CODE") {
				&{$opts->{nonzero}}($? >> 8);
			} else {
				confess "non-zero status (".($? >> 8).") from cmd ".join(" ", @args);
			}
		} elsif (exists $opts->{zero} and ref $opts->{zero} eq "CODE") {
			&{$opts->{zero}}();
		}
		1;
	};
	if ($@) {
		confess "$name: ".$@;
	}
}

# run buildah command with parameters
sub buildah
{
	my @args = @_;

	debug "buildah: args = ".join(" ", @args);
	cmd({name => "buildah"}, "/usr/bin/buildah", @args);
	return;
}

# compute container build order from dependencies
sub build_order_deps
{
	my $self = shift;
	my %deps; # dependencies in a hash of arrays, to be fed to Algorithm::Dependency::Source::HoA
	my $stages = $self->get_config("stages");
	if (ref $stages ne "HASH") {
		die "stages confguration must be a hash, got ".((ref $stages) ? ref $stages : "scalar");
	}

	# collect dependency data from each stage's configuration
	my @stages = keys %$stages;
	foreach my $stage (@stages) {
		my @stage_deps;

		# use consumes or depends parameters in each stage for dependency data
		# if consumes parameter exists, it declares stages which provide a tarball to this stage
		# if depends parameter exists, it declares stages which have any other dependency
		foreach my $param (qw(consumes depends)) {
			if (exists $stages->{$stage}{$param}) {
				if (ref $stages->{$stage}{$param} ne "ARRAY") {
					die "stage $stage '$param' entry must be an array, got "
						.((ref $stages->{$stage}{$param}) ? ref $stages->{$stage}{$param} : "scalar");
				}
				push @stage_deps, @{$stages->{$stage}{$param}};
			}
		}

		# save the dependency list, even if empty
		$deps{$stage} = \@stage_deps;
	}

	# compute build order from dependencies using Algorithm::Dependency
	my $Source = Algorithm::Dependency::Source::HoA->new( \%deps );
	my $algdep = Algorithm::Dependency->new(source => $Source);
	my $order = $algdep->schedule_all;
	Container::Buildah::debug "build order (computed): ".join(" ", @$order);
	$self->{order} = {};
	for (my $i=0; $i < scalar @$order; $i++) {
		$self->{order}{$order->[$i]} = $i;
	}
	Container::Buildah::debug "build order (data): ".join(" ", grep {$_."=>".$self->{order}{$_}} keys %{$self->{order}});
}

# run a container-build stage
sub stage
{
	my $self = shift;
	my $name = shift;
	my %opt = @_;

	# get flag: are we internal to the user namespace for container setup
	my $is_internal = (exists $opt{internal}) ? $opt{internal} : 0;

	# instantiate the Container::Buildah::Stage object for this stage's container
	my $stage = Container::Buildah::Stage->new(name => $name);

	# create timestamped log directory if it doesn't exist
	my $logdir_top = "log-".Container::Buildah->get_config("basename");
	my $logdir_time = "$logdir_top/".Container::Buildah->get_config("timestamp_str");
	foreach my $dir ($logdir_top, $logdir_time) {
		if (not  -d $dir) {
			mkdir $dir, 02770;
		}
	}
	if (-l $logdir_top."/current") {
		unlink $logdir_top."/current";
	}
	symlink Container::Buildah->get_config("timestamp_str"), $logdir_top."/current";

	# redirect STDOUT and STDERR to log file pipe for container stage
	my $stagelog;
	open($stagelog, '>>', $logdir_time."/".$name.($is_internal ? "-internal" : ""));
	$stagelog->autoflush(1);
	open(STDOUT, '>&', $stagelog);
	open(STDERR, '>&', $stagelog);

	# generate container and run this stage's function in it
	debug "begin $name (".($is_internal ? "internal" : "external").")";
	eval {
		if ($is_internal) {
			# run the internal stage function since we're within the mounted container namespace
			my $func = $stage->get_func;
			if (not defined $func) {
				die "stage $name internal: func not configured";
			}
			if (ref $func ne "CODE") {
				confess "stage $name internal: func is not a code reference - got "
					.(ref $func);
			}
			$stage->consume; # import tarball(s) from other stage(s), if configured
			$func->($stage);
			$stage->produce; # export tarball for another stage to use, if configured
		} else {
			# run the external stage wrapper which will mount the container namespace and call the internal stage in it
			$stage->launch_namespace;
		}
	};
	Container::Buildah::exception_handler $@;
	debug "end $name (".($is_internal ? "internal" : "external").")";

	# close output pipe
	close $stagelog;
	open(STDOUT, '>&', $self->{oldstdout});
	open(STDERR, '>&', $self->{oldstderr});
}

# process each defined stage of the container production pipeline
sub main
{
	# process command line
	my %cmd_opts;
	my @added_opts = (exists $Container::Buildah::init_config{added_opts} and ref $Container::Buildah::init_config{added_opts} eq "ARRAY") ? @{$Container::Buildah::init_config{added_opts}} : ();
	GetOptions(\%cmd_opts, "debug", "config:s", "internal:s", @added_opts);
	if (exists $cmd_opts{debug}) {
		Container::Buildah::set_debug($cmd_opts{debug});
	}

	# instantiate Container::Buildah object
	my $yaml_config = $cmd_opts{config};
	if (not defined $yaml_config) {
		foreach my $suffix (qw(yml yaml)) {
			if (-f $Container::Buildah::init_config{basename}.".".$suffix) {
				$yaml_config = $Container::Buildah::init_config{basename}.".".$suffix;
				last;
			}
		}
		if (not defined $yaml_config) {
			die "YAML configuration required to set software versions";
		}
	}
	my $self = Container::Buildah->instance(yaml_config => $yaml_config, config => \%Container::Buildah::init_config);

	# process config
	$self->{config}{opts} = \%cmd_opts;
	$self->{config}{arch} = Container::Buildah::get_arch();
	if (exists $Container::Buildah::init_config{required_config}
		and ref $Container::Buildah::init_config{required_config} eq "ARRAY")
	{
		$self->required_config(@{$Container::Buildah::init_config{required_config}});
	}

	if (exists $cmd_opts{internal}) {
		# run an internal stage inside a container user namespace if --internal=stage was specified
		$self->stage($cmd_opts{internal}, internal => 1);
	} else {
		# compute container build order from dependencies
		$self->build_order_deps;

		# external (outside the user namespaces) loop to run each stage
		foreach my $stage (sort {$self->{order}{$a} <=> $self->{order}{$b}}
			keys %{$self->{config}{stages}})
		{
			$self->stage($stage);
		}

		# if we get here, we're done
		say Container::Buildah->get_config("basename")." complete";
	}
}

# get OCI-recognized CPU architecture string for this system
# includes tweak to add v7 to armv7
sub get_arch
{
	my $arch = qx(/usr/bin/buildah info --format {{".host.arch"}});
	if ($? == -1) {
		die "get_arch: failed to execute: $!";
	} elsif ($? & 127) {
		printf STDERR "get_arch: child died with signal %d, %s coredump\n",
			($? & 127),  ($? & 128) ? 'with' : 'without';
		exit 1;
	} elsif ($? >> 8 != 0) {
		printf STDERR "get_arch: child exited with value %d\n", $? >> 8;
		exit 1;
	}
	if ($arch eq 'arm') {
	  open(my $cpuinfo_fh, '<', '/proc/cpuinfo')
		or die "get_arch: can't open /proc/cpuinfo: $!";
	  while (<$cpuinfo_fh>) {
		if (/^CPU architecture\s*:\s*(.*)/) {
			if ($1 eq "7") {
				$arch='armv7';
			}
			last;
		}
	  }
	  close $cpuinfo_fh;
	}
	return $arch;
}

#
# Container::Buildah::Stage - objects for stage containers
#

package Container::Buildah::Stage;
use constant MNT_ENV_NAME => "BUILDAHUTIL_MOUNT";
use constant AUTO_ACCESSORS => qw(commit consumes depends from func mnt name produces user user_home);
use subs (AUTO_ACCESSORS); # predeclare methods AUTOLOAD will generate if called, so UNIVERSAL->can() knows of them
use Cwd;
use Carp qw(confess);

sub new {
	my $class = shift;

	my $self = { @_ };
	bless $self, $class;

	# check for required name parameter
	if (not exists $self->{name}) {
		die __PACKAGE__.": cannot instantiate without a name parameter";
	}

	# get container mount point, if in the user namespace
	if (exists $ENV{MNT_ENV_NAME()}) {
		$self->{mnt} = $ENV{MNT_ENV_NAME()};
	}

	# get ref to stage configuation
	my $config = Container::Buildah->get_config("stages", $self->{name});
	if ((not defined $config) or (ref $config ne "HASH")) {
		die __PACKAGE__.": no configuration for stage ".$self->{name};
	}
	foreach my $key (keys %$config) {
		$self->{$key} = $config->{$key};
	}

	# check for missing stage config settings
	my @missing;
	foreach my $key (qw(from func)) {
		if (not exists $self->{$key}) {
			push @missing, $key;
		}
	}

	# fail if any required parameters are missing
	if (@missing) {
		die __PACKAGE__.": required parameters missing in stage ".$self->{name}.": ".join(" ", @missing);
	}

	return $self;
}

# return entry from stage configuration subset of Container::Buildah configuation
# Note: this reads the stage configuration data, not to be confused with buildah's config subcommand
sub stage_config
{
	my $self = shift;
	my $key = shift;

	if (exists $self->{$key}) {
		if (ref $self->{$key} and ref $self->{$key} ne "ARRAY") {
			return $self->{$key};
		}

		# if the value is a scalar, perform variable expansion
		return Container::Buildah::expand($self->{$key});
		
	}
	return;
}

# accessors - commented out but retained to show why AUTOLOAD was needed to generate accessor functions
#sub get_commit    { my $self = shift; return $self->stage_config("commit"); }
#sub get_consumes  { my $self = shift; return $self->stage_config("consumes"); }
#sub get_from      { my $self = shift; return $self->stage_config("from"); }
#sub get_func      { my $self = shift; return $self->stage_config("func"); }
#sub get_mnt       { my $self = shift; return $self->stage_config("mnt"); }
#sub get_name      { my $self = shift; return $self->stage_config("name"); }
#sub get_produces  { my $self = shift; return $self->stage_config("produces"); }
#sub get_user_home { my $self = shift; return $self->stage_config("user_home"); }
#sub get_user      { my $self = shift; return $self->stage_config("user"); }

# catch-all function for undefined functions - generate field accessor functions
sub AUTOLOAD
{
	# get the name of the attempted function call
	my ($name) = our $AUTOLOAD =~ /::(\w+)$/;

	# check valid field names - reject unknown
	if (substr($name, 0, 4) ne "get_") {
		confess "$name method call rejected: malformed function name can't be an accessor";
	}
	my $field_name = substr($name,4);
	my $field_ok = 0;
	foreach my $method_name (AUTO_ACCESSORS) {
		if ($name eq "get_".$method_name) {
			$field_ok = 1;
			last;
		}
	}
	if (not $field_ok) {
		confess "$name method call rejected: unrecognized field";
	}

	# generate accessor method to handle this field
	my $method = sub {
		my $self = shift;
		$self->isa(__PACKAGE__)
			or confess "$name method (generated by AUTOLOAD) expects ".__PACKAGE__." object, got "
				.((defined $self)?((ref $self)?ref $self:"scalar"):"undef");
		my $value = $self->stage_config($field_name);
		Container::Buildah::debug "$name: value=$value";
		return $value;
	};

	# install and call the newly-generated method
	no strict 'refs'; ## no critic (ProhibitNoStrict)
	*{ $AUTOLOAD } = $method; # install generated method in class symbol table
	goto &$method; # not the old stigmatized goto - replaces AUTOLOAD on call stack with newly generated $method
}

# define an empty destructor to force default behavior, don't let AUTOLOAD intercept it
sub DESTROY {}

# get container name
# generate it the first time
sub container_name
{
	my $self = shift;

	# derive container name
	if (not exists $self->{container_name}) {
		$self->{container_name} = Container::Buildah->get_config("basename")."_".$self->get_name;
	}
	return $self->{container_name};
}

# front-end to "buildah config" subcommand
# usage: $self->config( param => value, ...)
# Note: this is for the container's configuration, not to be confused with configuration data of this module
sub config
{
	my $self = shift;
	my %params = @_;

	# initialize argument list for buildah-config
	my @args = qw(--add-history);

	# process arguments which take a single string 
	foreach my $argname (qw(arch author cmd comment created-by domainname healthcheck healthcheck-interval
		healthcheck-retries healthcheck-start-period healthcheck-timeout history-comment hostname onbuild
		os shell stop-signal user workingdir))
	{
		if (exists $params{$argname}) {
			if (ref $params{$argname}) {
				confess "config: parameter '".$argname."' must be a scalar, got "
					.(ref $params{$argname});
			}
			push @args, "--$argname", $params{$argname};
			delete $params{$argname};
		}
	}

	# process arguments with take an array (converted to multiple occurrences on the command line)
	foreach my $argname (qw(annotation env label port volume)) {
		if (exists $params{$argname}) {
			if (not ref $params{$argname}) {
				push @args, "--$argname", $params{$argname};
			} elsif (ref $params{$argname} eq "ARRAY") {
				foreach my $entry (@{$params{$argname}}) {
					push @args, "--$argname", $entry;
				}
			} else {
				confess "config: parameter '".$argname."' must be a scalar or array, got "
					.(ref $params{$argname});
			}
			delete $params{$argname};
		}
	}

	# process entrypoint, which has unique formatting
	if (exists $params{entrypoint}) {
		if (exists $params{entrypoint}) {
			if (not ref $params{entrypoint}) {
				push @args, "--entrypoint", $params{entrypoint};
			} elsif (ref $params{entrypoint} eq "ARRAY") {
				push @args, "--entrypoint", '[ "'.join('", "', @{$params{entrypoint}}).'" ]';
			} else {
				confess "config: parameter 'entrypoint' must be a scalar or array, got "
					.(ref $params{entrypoint});
			}			
			delete $params{entrypoint};
		}
	}

	# error out if any unused parameters remain
	if (%params) {
		confess "config: received undefined parameters '".(join(" ", keys %params));
	}

	# run command
	Container::Buildah::buildah("config", @args, $self->container_name);
}

# front-end to "buildah copy" subcommand
# usage: $self->copy( {[dest => value]}, src, [src, ...] )
sub copy
{
	my $self = shift;
	my $params = {};
	if (ref $_[0] eq "HASH") {
		$params = shift;
	}
	my @paths = @_;

	# get special parameter dest if it exists
	my $dest = $params->{dest};
	delete $params->{dest};

	# initialize argument list for buildah-copy
	my @args = qw(--add-history);

	# process arguments which take a single string 
	foreach my $argname (qw(chown)) {
		if (exists $params->{$argname}) {
			if (ref $params->{$argname}) {
				confess "copy parameter '".$argname."' must be a scalar, got "
					.(ref $params->{$argname});
			}
			push @args, "--$argname", $params->{$argname};
			delete $params->{$argname};
		}
	}

	# error out if any unexpected parameters remain
	if (%$params) {
		confess "copy received undefined parameters '".(join(" ", keys %$params));
	}

	# run command
	Container::Buildah::buildah("copy", @args, $self->container_name, @paths, ($dest ? ($dest) : ()));
}

# front-end to "buildah run" subcommand
# usage: $self->run( [{param => value, ...}], [command], ... )
# Command parameter can be an array of strings for one command, or array of arrays of strings for multiple commands.
# This applies the same command-line arguments (from %params) to each command. To change parameters for a command,
# make a separate call to the function.
sub run
{
	my $self = shift;
	my $params = {};
	if (ref $_[0] eq "HASH") {
		$params = shift;
	}
	my @commands = @_;

	# initialize argument list for buildah-run
	my @args = qw(--add-history);

	# process arguments which take a single string 
	foreach my $argname (qw(cap-add cap-drop cni-config-dir cni-plugin-path ipc isolation network pid runtime
		runtime-flag no-pivot user uts))
	{
		if (exists $params->{$argname}) {
			if (ref $params->{$argname}) {
				confess "run parameter '".$argname."' must be a scalar, got "
					.(ref $params->{$argname});
			}
			push @args, "--$argname", $params->{$argname};
			delete $params->{$argname};
		}
	}

	# process arguments with take an array (converted to multiple occurrences on the command line)
	foreach my $argname (qw(mount volume)) {
		if (exists $params->{$argname}) {
			if (not ref $params->{$argname}) {
				push @args, "--$argname", $params->{$argname};
			} elsif (ref $params->{$argname} eq "ARRAY") {
				foreach my $entry (@{$params->{$argname}}) {
					push @args, "--$argname", $entry;
				}
			} else {
				confess "run parameter '".$argname."' must be a scalar or array, got "
					.(ref $params->{$argname});
			}
			delete $params->{$argname};
		}
	}

	# error out if any unexpected parameters remain
	if (%$params) {
		confess "run: received undefined parameters '".(join(" ", keys %$params));
	}

	# loop through provided commands
	# build outer array if only one command was provided
	if (not ref $commands[0]) {
		@commands = [@commands];
	}
	foreach my $command (@commands) {
		# if any entries are not arrays, temporarily make them into one
		if (not ref $command) {
			$command = [$command];
		} elsif (ref $command ne "ARRAY") {
			confess "run: command must be a scalar or array, got ".ref $command;
		}

		# run command
		Container::Buildah::buildah("run", @args, $self->container_name, '--', @$command);
	}
}

# remove a container by name if it already exists - we need the name
sub rmcontainer
{
	my $self = shift;

	Container::Buildah::cmd({name => "rmcontainer", nonzero => sub {},
		zero => sub {Container::Buildah::buildah("rm", $self->container_name);}},
		"/usr/bin/buildah inspect ".$self->container_name.' >/dev/null 2>&1');
}

# derive tarball name for stage which produces it
# defaults to the current stage
sub tarball
{
	my $self = shift;
	my $stage_name = shift // $self->get_name;
	return Container::Buildah->get_config("basename")."_".$stage_name.".tar.bz2";
}

# generic external wrapper function for all stages
# mount the container namespace and enter it to run the custom stage build function
sub launch_namespace
{
	my $self = shift;

	# check if this stage produces a deliverable to another stage
	my $produces = $self->get_produces;
	if (defined $produces) {
		# generate deliverable file name
		my $tarball_out = $self->tarball;

		# check if deliverable tarball file already exists
		if (my $status = Container::Buildah::check_deliverable($tarball_out)) {
			# set to build if the program has been updated more recently that the tarball result
			say STDERR "build tarball ($status): $tarball_out";
		} else {
			# skip this stage because the deliverable already exists and is up-to-date
			say STDERR "build tarball skipped - deliverable up-to-date $tarball_out";
			return;
		}
	}

	#
	# run container for this stage
	# commit it if configured (usually that's only for the final stage)
	# otherwise a stage is discarded except for its product tarball
	#

	# if the container exists, remove it
	$self->rmcontainer;

	# get the base image
	Container::Buildah::buildah("from", "--name=".$self->container_name, $self->get_from);

	# run the builder script in the container
	Container::Buildah::buildah("unshare", "--mount", MNT_ENV_NAME."=".$self->container_name, Container::Buildah::progpath(),
		"--internal=".$self->get_name, ($Container::Buildah::debug ? "--debug" : ()));

	# commit the container if configured
	my $commit = $self->get_commit;
	if (defined $commit) {
		if (not ref $commit) {
			Container::Buildah::buildah("commit", $self->container_name, $commit);
		} elsif (ref $commit eq "ARRAY") {
			foreach my $commit_tag (@$commit) {
				Container::Buildah::buildah("commit", $self->container_name, $commit_tag);
			}
		} else {
			confess "reference to ".(ref $commit)." not supported in commit - use scalar or array";
		}
	}
}

# import tarball(s) from other container stages if configured
sub consume
{
	my $self = shift;

	# create groups and users before import
	my $user = $self->get_user;
	if (defined $self->get_user) {
		my $user_name = $user;
		my ($uid, $group_name, $gid);
		if ($user =~ /:/) {
			($user_name, $group_name) = split /:/, $user;
			if ($user_name =~ /=/) {
				($user_name, $uid) = split /=/, $user_name; 
			}
			if ($group_name =~ /=/) {
				($group_name, $gid) = split /=/, $group_name; 
			}
		}
		# TODO - make this portable to containers based on other distros
		$self->run([qw(/sbin/apk add --no-cache shadow)]);
		if (defined $group_name) {
			$self->run(["/usr/sbin/groupadd", ((defined $gid) ? ("--gid=$gid") : ()), $group_name]);
		}
		my $user_home = $self->get_user_home;
		$self->run(
			["/usr/sbin/useradd", ((defined $uid) ? ("--uid=$uid") : ()),
				((defined $group_name) ? ("--gid=$group_name") : ()), 
				((defined $user_home) ? ("--home-dir=$user_home") : ()), $user_name],
			# TODO - make this portable to containers based on other distros
			[qw(/sbin/apk del shadow)]
		);
	}

	# import tarballs from each stage we depend upon
	my $consumes = $self->get_consumes;
	if (defined $consumes) {
		if (ref $consumes eq "ARRAY") {
			my @in_stages = @$consumes;
			my $cwd = getcwd();
			foreach my $in_stage (@in_stages) {
				my $tarball_in = $self->tarball($in_stage);
				Container::Buildah::debug "in ".$self->get_name." stage before untar; pid=$$ cwd=$cwd tarball=$tarball_in";
				(-f $tarball_in) or die "consume(".join(" ", @in_stages)."): ".$tarball_in." not found";
				Container::Buildah::buildah("add", "--add-history", $self->container_name, $tarball_in, "/");
			}
		} else {
			die "consume stage->consumes was set but not an array ref";
		}
	}
}

# export tarball for availability to other container stages if configured
sub produce
{
	my $self = shift;

	# export directories to tarball for product of this stage
	my $produces = $self->get_produces;
	if (defined $produces) {
		if (ref $produces eq "ARRAY") {
			my $tarball_out = $self->tarball;
			my @product_dirs;
			foreach my $product (@$produces) {
				push @product_dirs, Container::Buildah::dropslash($product);
			}

			# move any existing tarball to backup
			if ( -f $tarball_out ) {
				rename $tarball_out, $tarball_out.".bak";
			}

			# create the tarball
			my $cwd = getcwd();
			Container::Buildah::debug "in ".$self->get_name." stage before tar; pid=$$ cwd=$cwd product_dirs="
				.join(" ", @product_dirs);
			# ignore tar exit code 1 - appears to be unavoidable and meaningless when building on an overlayfs
			my $nonzero = sub { my $ret=shift; if ($ret>1) {die "tar exited with code $ret";}};
			Container::Buildah::cmd({name => "tar", nonzero => $nonzero}, "/usr/bin/tar", "--create", "--bzip2",
				"--preserve-permissions", "--sparse", "--file=".$tarball_out, "--directory=".$self->get_mnt, @product_dirs);
		} else {
			die "product: stage->consumes was set but not an array ref";
		}
	}
}

1;

