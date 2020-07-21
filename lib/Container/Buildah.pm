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

1;

