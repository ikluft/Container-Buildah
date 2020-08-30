# Container::Buildah::Subcommand
# ABSTRACT: wrapper class for Container::Buildah to run subcommands of buildah
# by Ian Kluft

## no critic (Modules::RequireExplicitPackage)
# 'use strict' and 'use warnings' included here
use Modern::Perl qw(2018); # require 5.26 security update
## use critic (Modules::RequireExplicitPackage)

package Container::Buildah::Subcommand;

use autodie;
use Carp qw(croak confess);
use IPC::Run;
use Data::Dumper;
require Container::Buildah;

# exports
use Exporter qw(import);
our @EXPORT_OK   = qw(process_params prog);

#
# parameter processing functions used by process_params()
#

# params_extract - set aside parameters which caller wants extracted for further processing that we can't generalize
# private class function
sub params_extract
{
	my ($defs, $params, $extract_ref) = @_;

	if (exists $defs->{extract}) {
		if (ref $defs->{extract} ne "ARRAY") {
			confess "process_params parameter 'extract' must be an array, got ".(ref $defs->{extract});
		}
		foreach my $argname (@{$defs->{extract}}) {
			if (exists $params->{$argname}) {
				$extract_ref->{$argname} = $params->{$argname};
				delete $params->{$argname};
			}
		}
	}
	return;
}

# param_arg_init - initialize argument list
# private class function
sub param_arg_init
{
	my ($defs, $arg_ref) = @_;

	if (exists $defs->{arg_init}) {
		if (not ref $defs->{arg_init}) {
			push @$arg_ref, $defs->{arg_init};
		} elsif (ref $defs->{arg_init} eq "ARRAY") {
			push @$arg_ref, @{$defs->{arg_init}};
		} else {
			confess "process_params parameter 'arg_init' must be scalar or array, got ".(ref $defs->{arg_init});
		}
	}
	return;
}

# param_exclusive - check for exclusive parameters - if any are present, it must be the only parameter
# private class function
sub param_exclusive
{
	my ($name, $defs, $params, $extract_ref) = @_;

	if (exists $defs->{exclusive}) {
		if (ref $defs->{exclusive} ne "ARRAY") {
			confess "process_params parameter 'exclusive' must be an array, got ".(ref $defs->{exclusive});
		}
		foreach my $argname (@{$defs->{exclusive}}) {
			if (exists $params->{$argname}) {
				# if other flags exist with an exclusive flag, that's an error
				if (scalar keys %$params > 1) {
					croak "$name parameter '".$argname."' is exclusive - cannot be passed with other parameters";
				}

				# exclusive flag saved in extracted fields so caller can detect it
				$extract_ref->{$argname} = $params->{$argname};
			}
		}
	}
	return;
}

# param_arg_flag - process arguments which are boolean flags, excluding those requiring true/false as a string
# private class function
sub param_arg_flag
{
	my ($name, $defs, $params, $arg_ref) = @_;

	if (exists $defs->{arg_flag}) {
		if (ref $defs->{arg_flag} ne "ARRAY") {
			confess "process_params parameter 'arg_flag' must be an array, got ".(ref $defs->{arg_flag});
		}
		foreach my $argname (@{$defs->{arg_flag}}) {
			if (exists $params->{$argname}) {
				if (ref $params->{$argname}) {
					confess "$name parameter '".$argname."' must be scalar, got ".(ref $params->{$argname});
				}
				push @$arg_ref, "--$argname";
				delete $params->{$argname};
			}
		}
	}
	return;
}

# param_arg_flag_str - process arguments which are boolean flags, requiring true/false as a string
# private class function
sub param_arg_flag_str
{
	my ($name, $defs, $params, $arg_ref) = @_;

	if (exists $defs->{arg_flag_str}) {
		if (ref $defs->{arg_flag_str} ne "ARRAY") {
			confess "process_params parameter 'arg_flag_str' must be an array, got ".(ref $defs->{arg_flag_str});
		}
		foreach my $argname (@{$defs->{arg_flag_str}}) {
			if (exists $params->{$argname}) {
				if (ref $params->{$argname}) {
					confess "$name parameter '".$argname."' must be scalar, got ".(ref $params->{$argname});
				}
				if ($params->{$argname} ne "true" and $params->{$argname} ne "false") {
					croak "$name parameter '".$argname."' must be 'true' or 'false', got '".$params->{$argname}."'";
				}
				push @$arg_ref, "--$argname", $params->{$argname};
				delete $params->{$argname};
			}
		}
	}
	return;
}

# param_arg_str - process arguments which take a single string
# private class function
sub param_arg_str
{
	my ($name, $defs, $params, $arg_ref) = @_;

	if (exists $defs->{arg_str}) {
		if (ref $defs->{arg_str} ne "ARRAY") {
			confess "process_params parameter 'arg_str' must be an array, got ".(ref $defs->{arg_str});
		}
		foreach my $argname (@{$defs->{arg_str}}) {
			if (exists $params->{$argname}) {
				if (ref $params->{$argname}) {
					confess "$name parameter '".$argname."' must be scalar, got ".(ref $params->{$argname});
				}
				push @$arg_ref, "--$argname", $params->{$argname};
				delete $params->{$argname};
			}
		}
	}
	return;
}

# param_arg_array - process arguments which take an array (converted to multiple occurrences on command line)
# private class function
sub param_arg_array
{
	my ($name, $defs, $params, $arg_ref) = @_;

	if (exists $defs->{arg_array}) {
		if (ref $defs->{arg_array} ne "ARRAY") {
			confess "process_params parameter 'arg_array' must be an array, got ".(ref $defs->{arg_array});
		}
		foreach my $argname (@{$defs->{arg_array}}) {
			if (exists $params->{$argname}) {
				if (not ref $params->{$argname}) {
					push @$arg_ref, "--$argname", $params->{$argname};
				} elsif (ref $params->{$argname} eq "ARRAY") {
					foreach my $entry (@{$params->{$argname}}) {
						push @$arg_ref, "--$argname", $entry;
					}
				} else {
					confess "$name parameter '".$argname."' must be scalar or array, got ".(ref $params->{$argname});
				}
				delete $params->{$argname};
			}
		}
	}
	return;
}

# param_arg_list - process arguments which are formatted as a list on the command-line
# (this is only used by buildah-config's entrypoint parameter)
# private class function
sub param_arg_list
{
	my ($name, $defs, $params, $arg_ref) = @_;

	if (exists $defs->{arg_list}) {
		if (ref $defs->{arg_list} ne "ARRAY") {
			confess "process_params parameter 'arg_list' must be an array, got ".(ref $defs->{arg_list});
		}
		foreach my $argname (@{$defs->{arg_list}}) {
			if (not ref $params->{$argname}) {
				push @$arg_ref, "--$argname", $params->{$argname};
			} elsif (ref $params->{$argname} eq "ARRAY") {
				push @$arg_ref, "--$argname", '[ "'.join('", "', @{$params->{$argname}}).'" ]';
			} else {
				confess "$name parameter '$argname' must be scalar or array, got ".(ref $params->{$argname});
			}
			delete $params->{$argname};
		}
	}
	return;
}

# parameter processing for buildah subcommand wrapper functions
# private class function - used only by Container::Buildah and Container::Buildah::Stage
#
# usage: ($extract, @args) = process_params({name => str, deflist => [ ... ], ... }, \%params);
#   deflist can be any of: extract exclusive arg_init arg_flag arg_flag_str arg_str arg_array arg_list
#
# All the buildah subcommand wrapper functions use similar logic to process parameters, which is centralized here.
# This builds an argument list to be used by a buildah subcommand.
# Parameters are the same names as command-line arguments of buildah subcommands.
sub process_params
{
	my $defs = shift; # defintions of parameters to process
	my $params = shift; # received parameters

	# results to build and return
	my @args; # argument list result to pass back
	my %extracted; # parameters extracted by name

	# get wrapper function name to use in error reporting
	# use caller function name if not provided
	my $name = $defs->{name} // (caller(1))[3];

	# set aside parameters which caller wants extracted for further processing that we can't generalize here
	params_extract($defs, $params, \%extracted);

	# initialize argument list
	param_arg_init($defs, \@args);

	# check for exclusive parameters - if any are present, it must be the only parameter
	param_exclusive($name, $defs, $params, \%extracted);

	# process arguments which are boolean flags, excluding those requiring true/false as a string
	param_arg_flag($name, $defs, $params, \@args);

	# process arguments which are boolean flags, requiring true/false as a string
	param_arg_flag_str($name, $defs, $params, \@args);

	# process arguments which take a single string
	param_arg_str($name, $defs, $params, \@args);

	# process arguments which take an array (converted to multiple occurrences on command line)
	param_arg_array($name, $defs, $params, \@args);

	# process arguments which are formatted as a list on the command-line
	# (this is only used by buildah-config's entrypoint parameter)
	param_arg_list($name, $defs, $params, \@args);

	# error out if any unexpected parameters remain
	if (%$params) {
		confess "$name received undefined parameters: ".(join(" ", keys %$params));
	}

	# return processed argument list
	return (\%extracted, @args);
}

#
# system access utility functions
#

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
sub prog
{
	my $progname = shift;
	my $cb = Container::Buildah->instance();

	if (!exists $cb->{prog}) {
		$cb->{prog} = {};
	}
	my $prog = $cb->{prog};

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
	my $found;
	for my $path ("/usr/bin", "/sbin", "/usr/sbin", "/bin") {
		if (-x "$path/$progname") {
			$prog->{$progname} = "$path/$progname";
			$found = $prog->{$progname};
			last;
		}
	}

	# return path, or error if we didn't find a known secure location for the program
	if (not defined $found) {
		croak "unknown secure location for $progname - install it or set $envprog to point to it";
	}
	return $found
}

#
# external command functions
#

# run a command and report errors
# private class method
sub cmd
{
	my ($class_or_obj, $opts, @in_args) = @_;
	my $cb = (ref $class_or_obj) ? $class_or_obj : $class_or_obj->instance();
	my $name = (exists $opts->{name}) ? $opts->{name} : "cmd";
	no autodie qw(system);

	eval {
		$cb->debug("cmd $name ".join(" ", @in_args));
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
# public class method
sub buildah
{
	my ($class_or_obj, @in_args) = @_;
	my $cb = (ref $class_or_obj) ? $class_or_obj : $class_or_obj->instance();

	$cb->debug("buildah: args = ".join(" ", @in_args));
	$cb->cmd({name => "buildah"}, prog("buildah"), @in_args);
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
# ✓ info
# - inspect (for image or container)
# - manifest-* later
# ✓ mount
# - pull
# - push
# - rename
# ✓ rm
# ✓ rmi
# ✓ tag
# ✓ umount
# ✓ unshare
# - version

# front end to "buildah info" subcommand
# usage: $cb->info([{format => format}])
# this uses YAML::XS with the assumption that buildah-info's JSON output is a proper subset of YAML
# public class method
sub info
{
	my ($class_or_obj, $param_ref) = @_;
	my $cb = (ref $class_or_obj) ? $class_or_obj : $class_or_obj->instance();
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

# front-end to "buildah mount" subcommand
# usage: $cb->mount({[notruncate => 1]}, container, ...)
# public class method
sub mount
{
	my ($class_or_obj, @in_args) = @_;
	my $cb = (ref $class_or_obj) ? $class_or_obj : $class_or_obj->instance();
	my $params = {};
	if (ref $in_args[0] eq "HASH") {
		$params = shift @in_args;
	}

	# process parameters
	my ($extract, @args) = process_params({name => 'mount', arg_flag => [qw(notruncate)]}, $params);

	# run buildah-tag
	$cb->buildah("mount", @args, @in_args);
	return;
}

# front end to "buildah tag" subcommand
# usage: $cb->tag({image => "image_name"}, new_name, ...)
# public class method
sub tag
{
	my ($class_or_obj, @in_args) = @_;
	my $cb = (ref $class_or_obj) ? $class_or_obj : $class_or_obj->instance();
	my $params = {};
	if (ref $in_args[0] eq "HASH") {
		$params = shift @in_args;
	}

	# process parameters
	my ($extract, @args) = process_params({name => 'tag', extract => [qw(image)]}, $params);
	my $image = $extract->{image}
		or croak "tag: image parameter required";

	# run buildah-tag
	$cb->buildah("tag", $image, @in_args);
	return;
}

# front end to "buildah rm" (remove container) subcommand
# usage: $cb->rm(container, [...])
#    or: $cb->rm({all => 1})
# public class method
sub rm
{
	my ($class_or_obj, @in_args) = @_;
	my $cb = (ref $class_or_obj) ? $class_or_obj : $class_or_obj->instance();
	my $params = {};
	if (ref $in_args[0] eq "HASH") {
		$params = shift @in_args;
	}

	# process parameters
	my ($extract, @args) = process_params({name => 'rm', arg_flag => [qw(all)], exclusive => [qw(all)]}, $params);

	# remove containers listed in arguments
	# buildah will error out if --all is provided with container names/ids
	$cb->buildah("rm", @args, @in_args);
	return;
}

# front end to "buildah rmi" (remove image) subcommand
# usage: $cb->rmi([{force => 1},] image, [...])
#    or: $cb->rmi({prune => 1})
#    or: $cb->rmi({all => 1})
# public class method
sub rmi
{
	my ($class_or_obj, @in_args) = @_;
	my $cb = (ref $class_or_obj) ? $class_or_obj : $class_or_obj->instance();
	my $params = {};
	if (ref $in_args[0] eq "HASH") {
		$params = shift @in_args;
	}

	# process parameters
	my ($extract, @args) = process_params({name => 'rmi', arg_flag => [qw(all prune force)],
		exclusive => [qw(all prune)]}, $params);

	# remove images listed in arguments
	# buildah will error out if --all or --prune are provided with image names/ids
	$cb->buildah("rmi", @args, @in_args);
	return;
}

# front-end to "buildah umount" subcommand
# usage: $cb->umount({[notruncate => 1]}, container, ...)
# public class method
sub umount
{
	my ($class_or_obj, @in_args) = @_;
	my $cb = (ref $class_or_obj) ? $class_or_obj : $class_or_obj->instance();
	my $params = {};
	if (ref $in_args[0] eq "HASH") {
		$params = shift @in_args;
	}

	# process parameters
	my ($extract, @args) = process_params({name => 'umount', arg_flag => [qw(all)]}, exclusive => [qw(all)], $params);

	# run buildah-tag
	$cb->buildah("umount", @args, @in_args);
	return;
}


# front end to "buildah unshare" (user namespace share) subcommand
# usage: $cb->unshare({container => "name_or_id", [envname => "env_var_name"]}, "cmd", "args", ... )
# public class method
sub unshare
{
	my ($class_or_obj, @in_args) = @_;
	my $cb = (ref $class_or_obj) ? $class_or_obj : $class_or_obj->instance();
	my $params = {};
	if (ref $in_args[0] eq "HASH") {
		$params = shift @in_args;
	}

	# process parameters
	my ($extract, @args) = process_params({name => 'unshare', extract => [qw(container envname)],
		arg_str => [qw(mount)]}, $params);

	# construct arguments for buildah-unshare command
	# note: --mount may be specified directly or constructed from container/envname - use only one way, not both
	if (exists $extract->{container}) {
		if (exists $extract->{envname}) {
			push @args, "--mount", $extract->{envname}."=".$extract->{container};
		} else {
			push @args, "--mount", $extract->{container};
		}
	}

	# run buildah-unshare command
	$cb->buildah("unshare", @args, "--", @in_args);
	return;
}

1;

__END__

=pod

=head1 SYNOPSIS
 
    use <Container::Buildah>;

  
=head1 DESCRIPTION

=method buildah

=method tag

=head1 BUGS AND LIMITATIONS

Please report bugs via GitHub at L<https://github.com/ikluft/Container-Buildah/issues>

Patches and enhancements may be submitted via a pull request at L<https://github.com/ikluft/Container-Buildah/pulls>

=cut
