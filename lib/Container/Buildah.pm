# Container::Buildah
# ABSTRACT: Use 'buildah' to enter namespace of OCI/Docker-compatible container image while building it
# by Ian Kluft

## no critic (Modules::RequireExplicitPackage)
# 'use strict' and 'use warnings' included here
use Modern::Perl qw(2018); # require 5.26 security update
## use critic (Modules::RequireExplicitPackage)

package Container::Buildah;

use autodie;
use Carp qw(croak confess);
use Exporter;
use Getopt::Long;
use Data::Dumper;
use IO::Handle;
use IPC::Run;
use File::Slurp;
use FindBin;
use File::stat;
use File::Sync qw(sync);
use Algorithm::Dependency;
use Algorithm::Dependency::Source::HoA;
use YAML::XS;
use Template;

use parent qw(Class::Singleton Exporter);

#
# initialize environment
#

# allow export of class functions
our @EXPORT_OK = qw(buildah);

# globals
my $debug=0;
my %template_config = (
	INTERPOLATE  => 1,
	POST_CHOMP   => 1,
	RECURSION    => 1,
	EVAL_PERL    => 0,
	PRE_CHOMP    => 2,
	POST_CHOMP   => 2,
);
my %init_config;

# initialization on the singleton instance
# see parent Class::Singleton
# private class method - required by parent Class::Singleton
## no critic (Subroutines::ProhibitUnusedPrivateSubroutines, Miscellanea::ProhibitUnrestrictedNoCritic))
sub _new_instance
{
	my ($class, %params) = @_;
	my $self  = bless { }, $class;

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
	foreach my $key (keys %init_config) {
		$self->{config}{$key} = $init_config{$key};
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
			## no critic (Variables::RequireLocalizedPunctuationVars, Miscellanea::ProhibitUnrestrictedNoCritic)
			$ENV{$timestamp_envname} = $self->{config}{timestamp_str};
		}
	} else {
		croak __PACKAGE__.": required basename initialization parameter not found";
	}

	# Template setup
	$self->{template} = Template->new(\%template_config);

	# redirect STDIN from /dev/null so subprocesses run automated and can't prompt STDIN
	open STDIN, "<", "/dev/null"
		or croak "failed to redirect STDIN";

	# save STDOUT and STDERR so they can be restored after redirects
	open($self->{oldstdout}, '>&STDOUT')
		or croak "Can't dup STDOUT: $!";
	open($self->{oldstderr}, '>&STDERR')
		or croak "Can't dup STDERR: $!";

	return $self;
}
## use critic (Subroutines::ProhibitUnusedPrivateSubroutines, Miscellanea::ProhibitUnrestrictedNoCritic))

#
# configuration/utility functions
#

# initialize configuration
# public class function
sub init_config
{
	%init_config = @_;
	return;
}

# print status messages
# public class function
sub status
{
	# get Container::Buildah ref from method-call parameter or class singleton instance
	my @in_args = @_;
	my $cb = ((ref $in_args[0]) and (ref $in_args[0] eq "Container::Buildah")) ? shift @in_args
		: Container::Buildah->instance();

	# print status message
	say STDOUT "=== status: ".join(" ", @in_args);
	if ((exists $cb->{oldstdout}) and ($cb->{oldstdout}->fileno != fileno(STDERR))) {
		$cb->{oldstdout}->print("=== status: ".join(" ", @in_args)."\n");
	}
	return;
}

# print debug messages
# public class function
sub debug
{
	if ($debug) {
		# get Container::Buildah ref from method-call parameter or class singleton instance
		my @in_args = @_;
		my $cb = ((ref $in_args[0]) and (ref $in_args[0] eq "Container::Buildah")) ? shift @in_args
			: Container::Buildah->instance();

		# print debug message
		say STDERR "--- debug: ".join(" ", @in_args);
		if ((exists $cb->{oldstderr}) and ($cb->{oldstderr}->fileno != fileno(STDERR))) {
			$cb->{oldstderr}->print("--- debug: ".join(" ", @in_args)."\n");
		}
	}
	return;
}

# template and variable expansion
# private class function
sub expand
{
	my $value = shift;

	# process array values sequentially
	if (ref $value eq "ARRAY") {
		my @result;
		foreach my $subvalue (@$value) {
			push @result, expand($subvalue);
		}
		return \@result;
	}

	# process scalar value
	my $output;
	my $cb = Container::Buildah->instance();
	$cb->{template}->process(\$value, $cb->{config}, \$output);
	debug "expand: $value -> $output";

	# expand templates as long as any remain, up to 10 iterations
	my $count=0;
	while ($output =~ / \[% .* %\] /x and $count++ < 10) {
		$value = $output;
		$output = ""; # clear because template concatenates to it
		$cb->{template}->process(\$value, $cb->{config}, \$output);
		debug "expand ($count): $value -> $output";
	}
	return $output;
}

# get configuration value
# public class method
sub get_config
{
	my ($class_or_obj, @path) = @_;
	my $self = (ref $class_or_obj) ? $class_or_obj : $class_or_obj->instance();

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

		# if the value is scalar, perform variable expansion
		return expand($node->{$key});
	}
	return;
}

# allow caller to enforce its required configuration
# public class method
sub required_config
{
	my ($class_or_obj, @in_args) = @_;
	my $self = (ref $class_or_obj) ? $class_or_obj : $class_or_obj->instance();

	# check for missing config parameters required by program
	my @missing;
	foreach my $key (@in_args) {
		if (not exists $self->{config}{$key}) {
			push @missing, $key;
		}
	}

	# fail if any required parameters are missing
	if (@missing) {
		croak __PACKAGE__.": required configuration parameters missing: ".join(" ", @missing);
	}
}

# get debug mode value
# public class function
sub get_debug
{
	return $debug;
}

# set debug mode on or off
# public class function
sub set_debug
{
	$debug = (shift ? 1 : 0); # save boolean value
	return;
}

#
# system access utility functions
#

# get path to the executing script
# used for file dependency checks and re-running the script in a container namespace
# private class function
sub progpath
{
	state $progpath = "$FindBin::Bin/$FindBin::Script";
	return $progpath;
}

# generate name of environment variable for where to find a command
# this is broken out as a separate function for tests to use it
# private class function
sub envprog
{
	my $progname = shift;
	my $envprog = (uc $progname)."_PROG";
	$envprog =~ s/[\W-]+/_/xg; # collapse any sequences of non-alphanumeric/non-underscore to a single underscore
	return $envprog;
}

# look up secure program path
# private class function
## no critic (RequireFinalReturn)
sub prog
{
	my $progname = shift;
	my $self = Container::Buildah->instance();

	if (!exists $self->{prog}) {
		$self->{prog} = {};
	}
	my $prog = $self->{prog};

	# call with undef to initialize cache (mainly needed for testing because normal use will auto-create it)
	if (!defined $progname) {
		return;
	}

	# return value from cache if found
	if (exists $prog->{$progname}) {
		return $prog->{$progname};
	}

	# if we didn't have the location of the program, look for it and cache the result
	my $envprog = envprog($progname);
	if (exists $ENV{$envprog} and -x $ENV{$envprog}) {
		$prog->{$progname} = $ENV{$envprog};
		return $prog->{$progname};
	}

	# search paths in order emphasizing recent Linux Filesystem that prefers /usr/bin, then Unix PATH order
	for my $path ("/usr/bin", "/sbin", "/usr/sbin", "/bin") {
		if (-x "$path/$progname") {
			$prog->{$progname} = "$path/$progname";
			return $prog->{$progname};
		}
	}

	# if we get here, we didn't find a known secure location for the program
	croak "unknown secure location for $progname - install it or set $envprog to point to it";
}
## use critic

# get OCI-recognized CPU architecture string for this system
# includes tweak to add v7 to armv7
# private class function
sub get_arch
{
	my $arch;
	IPC::Run::run [prog("buildah"), "info", "--format", q({{.host.arch}})], \undef, \$arch
		or croak "get_arch: failed to run buildah - exit code $?" ;
	if ($arch eq 'arm') {
		my $cpuinfo = File::Slurp::read_file('/proc/cpuinfo', err_mode => "croak");
		if (/ ^ CPU \s architecture \s* : \s* (.*) $ /x) {
			if ($1 eq "7") {
				$arch='armv7';
			}
		}
	}
	return $arch;
}

# parameter processing for buildah subcommand wrapper functions
# private class function - used only by Container::Buildah and Container::Buildah::Stage
#
# usage: ($extracted, @args) = process_params({name => str, deflist => [ ... ], ... }, \%params);
#   deflist can be any of: extract exclusive args_init args_flag args_flag_str args_str args_array args_list
#
# All the buildah subcommand wrapper functions use similar logic to process parameters, which is centralized here.
# This builds an argument list to be used by a buildah subcommand.
# Parameters are the same names as command-line arguments of buildah subcommands.
#
# TODO: reduce the McCabe complexity metric on this without making it less readable
## no critic (Subroutines::ProhibitExcessComplexity)
sub process_params
{
	my $defs = shift; # defintions of parameters to process
	my $params = shift; # received parameters

	# results to build and return
	my @args; # argument list result to pass back
	my %extracted; # parameters extracted by name

	# get wrapper function name to use in error reporting
	# use caller function name if not provided
	my $name = $defs->{name} // (caller(0))[3];

	# set aside parameters which caller wants extracted for further processing that we can't generalize here
	if (exists $defs->{extract}) {
		if (ref $defs->{extract} ne "ARRAY") {
			confess "process_params parameter 'extract' must be an array, got ".(ref $defs->{extract});
		}
		foreach my $argname (@{$defs->{extract}}) {
			if (exists $params->{$argname}) {
				$extracted{$argname} = $params->{$argname};
				delete $params->{$argname};
			}
		}
	}

	# initialize argument list
	if (exists $defs->{args_init}) {
		if (not ref $defs->{args_init}) {
			push @args, $defs->{args_init};
		} elsif (ref $defs->{args_init} eq "ARRAY") {
			push @args, @{$defs->{args_init}};
		} else {
			confess "process_params parameter 'args_init' must be scalar or array, got ".(ref $defs->{args_init});
		}
	}

	# check for exclusive parameters - if any are present, it must be the only parameter
	if (exists $defs->{exclusive}) {
		if (ref $defs->{exclusive} ne "ARRAY") {
			confess "process_params parameter 'exclusive' must be an array, got ".(ref $defs->{exclusive});
		}
		foreach my $argname (@{$defs->{exclusive}}) {
			if (exists $params->{$argname}) {
				if (scalar keys %$params > 1) {
					croak "$name parameter '".$argname."' is exclusive - cannot be passed with other parameters";
				}
			}
		}
	}

	# process arguments which are boolean flags, excluding those requiring true/false as a string
	if (exists $defs->{args_flag}) {
		if (ref $defs->{args_flag} ne "ARRAY") {
			confess "process_params parameter 'args_flag' must be an array, got ".(ref $defs->{args_flag});
		}
		foreach my $argname (@{$defs->{args_flag}}) {
			if (exists $params->{$argname}) {
				if (ref $params->{$argname}) {
					confess "$name parameter '".$argname."' must be scalar, got ".(ref $params->{$argname});
				}
				push @args, "--$argname";
				delete $params->{$argname};
			}
		}
	}

	# process arguments which are boolean flags, requiring true/false as a string
	if (exists $defs->{args_flag_str}) {
		if (ref $defs->{args_flag_str} ne "ARRAY") {
			confess "process_params parameter 'args_flag_str' must be an array, got ".(ref $defs->{args_flag_str});
		}
		foreach my $argname (@{$defs->{args_flag_str}}) {
			if (exists $params->{$argname}) {
				if (ref $params->{$argname}) {
					confess "$name parameter '".$argname."' must be scalar, got ".(ref $params->{$argname});
				}
				if ($params->{$argname} ne "true" and $params->{$argname} ne "false") {
					croak "$name parameter '".$argname."' must be 'true' or 'false', got '".$params->{$argname}."'";
				}
				push @args, "--$argname", $params->{$argname};
				delete $params->{$argname};
			}
		}
	}

	# process arguments which take a single string
	if (exists $defs->{args_str}) {
		if (ref $defs->{args_str} ne "ARRAY") {
			confess "process_params parameter 'args_str' must be an array, got ".(ref $defs->{args_str});
		}
		foreach my $argname (@{$defs->{args_str}}) {
			if (exists $params->{$argname}) {
				if (ref $params->{$argname}) {
					confess "$name parameter '".$argname."' must be scalar, got ".(ref $params->{$argname});
				}
				push @args, "--$argname", $params->{$argname};
				delete $params->{$argname};
			}
		}
	}

	# process arguments which take an array (converted to multiple occurrences on the command line)
	if (exists $defs->{args_array}) {
		if (ref $defs->{args_array} ne "ARRAY") {
			confess "process_params parameter 'args_array' must be an array, got ".(ref $defs->{args_array});
		}
		foreach my $argname (@{$defs->{args_array}}) {
			if (exists $params->{$argname}) {
				if (not ref $params->{$argname}) {
					push @args, "--$argname", $params->{$argname};
				} elsif (ref $params->{$argname} eq "ARRAY") {
					foreach my $entry (@{$params->{$argname}}) {
						push @args, "--$argname", $entry;
					}
				} else {
					confess "$name parameter '".$argname."' must be scalar or array, got ".(ref $params->{$argname});
				}
				delete $params->{$argname};
			}
		}
	}

	# process arguments which are formatted as a list on the command-line
	# (this is only used by buildah-config's entrypoint parameter)
	if (exists $defs->{args_list}) {
		if (ref $defs->{args_list} ne "ARRAY") {
			confess "process_params parameter 'args_list' must be an array, got ".(ref $defs->{args_list});
		}
		foreach my $argname (@{$defs->{args_list}}) {
			if (not ref $params->{$argname}) {
				push @args, "--$argname", $params->{$argname};
			} elsif (ref $params->{$argname} eq "ARRAY") {
				push @args, "--$argname", '[ "'.join('", "', @{$params->{$argname}}).'" ]';
			} else {
				confess "$name parameter '$argname' must be scalar or array, got ".(ref $params->{$argname});
			}
			delete $params->{$argname};
		}
	}

	# error out if any unexpected parameters remain
	if (%$params) {
		confess "$name received undefined parameters: ".(join(" ", keys %$params));
	}

	# return processed argument list
	return (\%extracted, @args);
}
## use critic (Subroutines::ProhibitExcessComplexity)

#
# exception handling
#

# handle exceptions from eval blocks
# private class function
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
		my $cb = Container::Buildah->instance();
		open(STDOUT, '>&', $cb->{oldstdout});
		open(STDERR, '>&', $cb->{oldstderr});

		# report status if possible and exit
		my $basename = $cb->{config}{basename} // "unnamed container";
		say STDERR $basename." failed";
		exit 1;
	}
}

#
# external command functions
#

# run a command and report errors
# private class function
sub cmd
{
	my ($opts, @in_args) = @_;
	my $name = (exists $opts->{name}) ? $opts->{name} : "cmd";
	no autodie qw(system);

	eval {
		debug "cmd $name ".join(" ", @in_args);
		system(@in_args);
		if ($? == -1) {
			confess "failed to execute command (".join(" ", @in_args)."): $!";
		}
		if ($? & 127) {
			confess sprintf "command (".join(" ", @in_args)." child died with signal %d, %s coredump\n",
				($? & 127),  ($? & 128) ? 'with' : 'without';
		}
		if ($? >> 8 != 0) {
			if (exists $opts->{nonzero} and ref $opts->{nonzero} eq "CODE") {
				&{$opts->{nonzero}}($? >> 8);
			} else {
				confess "non-zero status (".($? >> 8).") from cmd ".join(" ", @in_args);
			}
		} elsif (exists $opts->{zero} and ref $opts->{zero} eq "CODE") {
			&{$opts->{zero}}();
		}
		1;
	} or do {
		if ($@) {
			confess "$name: ".$@;
		}
	};
	return;
}

# run buildah command with parameters
# public class function
sub buildah
{
	my @in_args = @_;

	debug "buildah: args = ".join(" ", @in_args);
	cmd({name => "buildah"}, prog("buildah"), @in_args);
	return;
}

#
# buildah subcommand wrapper methods
# for subcommands which do not have a container name parameter (those are in Container::Buildah::Stage)
#

# TODO list for wrapper functions
# - bud
# - containers
# - images
# - info
# - inspect (for image or container)
# - manifest-* later
# - mount (for image or container)
# - pull
# - push
# - rename
# ✓ rm
# ✓ rmi
# ✓ tag
# - umount (for image or container)
# ✓ unshare
# - version

# front end to "buildah info" subcommand
# usage: $cb->info([{format => format}])
# this uses YAML::XS with the assumption that buildah-info's JSON output is a proper subset of YAML
sub info
{
	my ($class_or_obj, $param_ref) = @_;
	my $self = (ref $class_or_obj) ? $class_or_obj : $class_or_obj->instance();
	my $params = {};
	if ((defined $param_ref) and (ref $param_ref eq "HASH")) {
		$params = %$param_ref;
	}

	# TODO add --format queries; until then no parameter processing is done
	
	# read buildah-info's JSON output with YAML::XS since YAML is a superset of JSON
	my $yaml;
	IPC::Run::run [prog("buildah"), "info"], \undef, \$yaml
		or croak "info(): failed to run buildah - exit code $?" ;
	my $info = YAML::XS::Load($yaml);
	return $info;
}

# front end to "buildah tag" subcommand
# usage: $cb->tag({image => "image_name"}, new_name, ...)
# public class method
sub tag
{
	my ($class_or_obj, @tags) = @_;
	my $self = (ref $class_or_obj) ? $class_or_obj : $class_or_obj->instance();
	my $params = {};
	if (ref $tags[0] eq "HASH") {
		$params = shift @tags;
	}

	# get image name parameter
	my $image = $params->{image}
		or croak "tag: image parameter required";
	delete $params->{image};

	# error out if any unexpected parameters remain
	if (%$params) {
		confess "tag received undefined parameters '".(join(" ", keys %$params));
	}

	# run buildah-tag
	buildah("tag", $image, @tags);
	return;
}

# front end to "buildah rm" (remove container) subcommand
# usage: $cb->rm(container, [...])
#    or: $cb->rm({all => 1})
sub rm
{
	my ($class_or_obj, @containers) = @_;
	my $self = (ref $class_or_obj) ? $class_or_obj : $class_or_obj->instance();
	my $params = {};
	if (ref $containers[0] eq "HASH") {
		$params = shift @containers;
	}

	# if "all" parameter is provided, remove all containers
	if ((exists $params->{all}) and $params->{all}) {
		buildah("rm", "--all");
		return;
	}

	# remove containers listed in arguments
	buildah("rm", @containers);
	return;
}

# front end to "buildah rmi" (remove image) subcommand
# usage: $cb->rmi([{force => 1},] image, [...])
#    or: $cb->rmi({prune => 1})
#    or: $cb->rmi({all => 1})
sub rmi
{
	my ($class_or_obj, @images) = @_;
	my $self = (ref $class_or_obj) ? $class_or_obj : $class_or_obj->instance();
	my $params = {};
	if (ref $images[0] eq "HASH") {
		$params = shift @images;
	}

	# if "all" parameter is provides, remove all images
	if ((exists $params->{all}) and $params->{all}) {
		buildah("rmi", "--all");
		return;
	}

	# if "prune" parameter is provides, remove all images
	if ((exists $params->{prune}) and $params->{prune}) {
		buildah("rmi", "--prune");
		return;
	}

	# process force parameter
	my @args;
	if ((exists $params->{force}) and $params->{force}) {
		push @args, "--force";
	}

	# remove images listed in arguments
	buildah("rmi", @args, @images);
	return;
}

# front end to "buildah unshare" (user namespace share) subcommand
# usage: $cb->unshare({container => "name_or_id", [envname => "env_var_name"]}, "cmd", "args", ... )
sub unshare
{
	my ($class_or_obj, @in_args) = @_;
	my $self = (ref $class_or_obj) ? $class_or_obj : $class_or_obj->instance();
	my $params = {};
	if (ref $in_args[0] eq "HASH") {
		$params = shift @in_args;
	}
	
	# construct arguments for buildah-unshare command
	my @args;
	if (exists $params->{container}) {
		if (exists $params->{envname}) {
			push @args, "--mount", $params->{envname}."=".$params->{container};
			delete $params->{envname};
		} else {
			push @args, "--mount", $params->{container};
		}
		delete $params->{container};
	}

	# error out if any unexpected parameters remain
	if (%$params) {
		confess "run: received undefined parameters '".(join(" ", keys %$params));
	}

	# run buildah-unshare command
	buildah("unshare", @args, "--", @in_args);
	return;
}

#
# build stage management functions
#

# compute container build order from dependencies
# private class method
sub build_order_deps
{
	my $self = shift;
	my %deps; # dependencies in a hash of arrays, to be fed to Algorithm::Dependency::Source::HoA
	my $stages = $self->get_config("stages");
	if (ref $stages ne "HASH") {
		croak "stages confguration must be a hash, got ".((ref $stages) ? ref $stages : "scalar");
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
					croak "stage $stage '$param' entry must be an array, got "
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
	debug "build order (computed): ".join(" ", @$order);
	$self->{order} = {};
	for (my $i=0; $i < scalar @$order; $i++) {
		$self->{order}{$order->[$i]} = $i;
	}
	debug "build order (data): ".join(" ", grep {$_."=>".$self->{order}{$_}} keys %{$self->{order}});
	return;
}

# run a container-build stage
# private class method
sub stage
{
	my ($self, $name, %opt) = @_;

	# get flag: are we internal to the user namespace for container setup
	my $is_internal = (exists $opt{internal}) ? $opt{internal} : 0;

	# instantiate the Container::Buildah::Stage object for this stage's container
	require Container::Buildah::Stage;
	my $stage = Container::Buildah::Stage->new(name => $name);

	# create timestamped log directory if it doesn't exist
	my $logdir_top = "log-".Container::Buildah->get_config("basename");
	my $logdir_time = "$logdir_top/".Container::Buildah->get_config("timestamp_str");
	foreach my $dir ($logdir_top, $logdir_time) {
		if (not  -d $dir) {
			mkdir $dir, 02770;
		}
	}
	if (-l "$logdir_top/current") {
		unlink "$logdir_top/current";
	}
	symlink Container::Buildah->get_config("timestamp_str"), $logdir_top."/current";

	# redirect STDOUT and STDERR to log file pipe for container stage
	## no critic (InputOutput::RequireBriefOpen, Miscellanea::ProhibitUnrestrictedNoCritic)
	my $stagelog;
	open($stagelog, '>>', $logdir_time."/".$name.($is_internal ? "-internal" : ""));
	$stagelog->autoflush(1);
	open(STDOUT, '>&', $stagelog);
	open(STDERR, '>&', $stagelog);

	# generate container and run this stage's function in it
	$stage->status("begin (".($is_internal ? "internal" : "external").")");
	eval {
		if ($is_internal) {
			#
			# run the internal stage function since we're within the mounted container namespace
			#

			# retrieve the internal stage functions
			my $func_deps = $stage->get_func_deps;
			my $func_exec = $stage->get_func_exec;

			# enforce required func_exec configuration (func_deps is optional)
			if (not defined $func_exec) {
				croak "stage $name internal: func_exec not configured";
			}
			if (ref $func_exec ne "CODE") {
				confess "stage $name internal: func_exec is not a code reference - got "
					.(ref $func_exec);
			}

			# run deps & exec functions for the stage, process consumed or produced tarballs
			if ((defined $func_deps) and (ref $func_deps eq "CODE")) {
				$stage->status("func_deps");
				$func_deps->($stage);
			} else {
				$stage->status("func_deps - skipped, not configured");
			}
			$stage->status("consume");
			$stage->consume; # import tarball(s) from other stage(s), if configured
			$stage->status("func_exec");
			$func_exec->($stage);
			$stage->status("produce");
			$stage->produce; # export tarball for another stage to use, if configured
		} else {
			# run the external stage wrapper which will mount the container namespace and call the internal stage in it
			$stage->status("launch_namespace");
			$stage->launch_namespace;
		}
		1;
	} or exception_handler $@;
	$stage->status("end (".($is_internal ? "internal" : "external").")");

	# close output pipe
	close $stagelog;
	open(STDOUT, '>&', $self->{oldstdout});
	open(STDERR, '>&', $self->{oldstderr});
	return;
}

#
# process mainline
#

# process each defined stage of the container production pipeline
# public class function
sub main
{
	# process command line
	my %cmd_opts;
	my @added_opts = (exists $init_config{added_opts} and ref $init_config{added_opts} eq "ARRAY")
		? @{$init_config{added_opts}} : ();
	GetOptions(\%cmd_opts, "debug", "config:s", "internal:s", @added_opts);
	if (exists $cmd_opts{debug}) {
		set_debug($cmd_opts{debug});
	}

	# instantiate Container::Buildah object
	my @do_yaml;
	if (not exists $init_config{testing_skip_yaml}) {
		my $yaml_config = $cmd_opts{config};
		if (not defined $yaml_config) {
			foreach my $suffix (qw(yml yaml)) {
				if (-f $init_config{basename}.".".$suffix) {
					$yaml_config = $init_config{basename}.".".$suffix;
					last;
				}
			}
			if (not defined $yaml_config) {
				croak "YAML configuration required to set software versions";
			}
		}
		@do_yaml = (yaml_config => $yaml_config);
	}
	my $self = Container::Buildah->instance(@do_yaml);

	# process config
	$self->{config}{opts} = \%cmd_opts;
	$self->{config}{arch} = get_arch();
	if (exists $init_config{required_config}
		and ref $init_config{required_config} eq "ARRAY")
	{
		$self->required_config(@{$init_config{required_config}});
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
	return 0;
}

1;

__END__

=pod

=head1 SYNOPSIS
 
    use <Container::Buildah>;

	# configure container build stages
	Container::Buildah::init_config(
		basename => "swpkg",
		base_image => 'docker://docker.io/alpine:[% alpine_version %]',
		stages => {
			build => {
				from => "[% base_image %]",
				func_exec => \&stage_build,
				produces => [qw(/opt/swpkg-apk)],
			},
			runtime => {
				from => "[% base_image %]",
				consumes => [qw(build)],
				func_exec => \&stage_runtime,
				commit => ["[% basename %]:[% swpkg_version %]", "[% basename %]:latest"],
			}
		},
		swpkg_version => "9.16.4",
	);

	# functions to run each stage inside their container namespaces
	sub stage_build {
		my $stage = shift;
		# code to run inside the namespace of the build container
		# set up build container and copy newly-built Alpine APK packages into /opt/swpkg-apk ...
		# See Container::Buildah:Stage for the object passed to each stage function
	}
	sub stage_runtime {
		my $stage = shift;
		# code to run inside the namespace of the runtime container
		# set up runtime container including installing Alpine APK packages from /opt/swpkg-apk ...
		# See Container::Buildah:Stage for the object passed to each stage function
	}

	# Container::Buildah::main serves as script mainline including processing command-line arguments
	Container::Buildah::main(); # run all the container stages
  
=head1 DESCRIPTION

B<Container::Buildah> allows Perl scripts to build OCI/Docker-compatible container images using the Open Source
I<buildah> command. Containers may be pipelined so the product of a build stage is consumed by one or more others.

The B<Container::Buildah> module grew out of a wrapper script to run code inside the user namespace of a
container under construction. That remains the core of its purpose. It simplifies rootless builds of containers.

B<Container::Buildah> may be used to write a script to configure container build stages.
The configuration of each build stage contains a reference to a callback function which will run inside the
user namespace of the container in order to build it.
The function is analagous to a Dockerfile, except that it's programmable with access to computation and the system.

The I<buildah> command has subcommands equivalent to Dockerfile directives.
For each stage of a container build, B<Container::Buildah> creates a B<Container::Buildah::Stage> object
and passes it to the callback function for that stage.
There are wrapper methods in B<Container::Buildah::Stage> for
subcommands of buildah which take a container name as a parameter.

The B<Container::Buildah> module has one singleton instance per program.
It contains configuration data for a container build process.
The data is similar to what would be in a Dockerfile, except this module makes it scriptable.

=func init_config

=func status

prints a list of strings to STDOUT

=func debug

prints a list of strings to STDERR, if debugging mode is on

=method get_config

=method required_config

=method get_debug

return boolean value of debug mode flag

=method set_debug

take a boolean value parameter to set the debug mode flag

=method prog

=method buildah

=method tag

=method main

=head1 BUGS AND LIMITATIONS

Please report bugs via GitHub at L<https://github.com/ikluft/Container-Buildah/issues>

Patches and enhancements may be submitted via a pull request at L<https://github.com/ikluft/Container-Buildah/pulls>

=cut
