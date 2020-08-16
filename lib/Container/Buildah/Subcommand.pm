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
use Readonly;
use Container::Buildah;
use Data::Dumper;

# list of utility and subcommand functions which Container::Buildah delegates to this class if called there
Readonly::Array my @delegated_functions => qw(process_params envprog prog cmd buildah bud containers images info inspect
	mount pull push rename rm rmi tag umount unshare version);

# export subcommand wrapper functions to Container::Buildah so it forwards these calls here
sub setup_delegation
{
	# export delegated functions to Container::Buildah
	foreach my $funcname (@delegated_functions) {
		no strict 'refs'; ## no critic (ProhibitNoStrict)
		*{ "Container::Buildah::$funcname" } = \&$funcname;
	}
	return;
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
		Container::Buildah::debug "cmd $name ".join(" ", @in_args);
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

	Container::Buildah::debug "buildah: args = ".join(" ", @in_args);
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
