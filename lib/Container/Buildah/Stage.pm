#!/usr/bin/perl
# Container::Buildah::Stage
# ABSTRACT: object used by Container::Buildah to track a stage of a multi-stage container build
# by Ian Kluft
use strict;
use warnings;

package Container::Buildah::Stage;
use Modern::Perl qw(2018); # oldest versions of Perl this will run on
use autodie;

use Carp qw(confess);
use Cwd;
use Container::Buildah;

use constant MNT_ENV_NAME => "BUILDAHUTIL_MOUNT";
use constant AUTO_ACCESSORS => qw(commit consumes depends from func mnt name produces user user_home);
use subs (AUTO_ACCESSORS); # predeclare methods AUTOLOAD will generate if called, so UNIVERSAL->can() knows of them

=pod

=head1 NAME

Container::Buildah:Stage - object used by Container::Buildah to track a stage of a multi-stage container build

=head1 DESCRIPTION

B<Container::Buildah:Stage> objects are created and used by B<Container::Buildah>.
These are passed to the callback function for each build-stage container.

The class contains methods which are wrappers for the buildah subcommands that require a container name parameter
on the command line.
However, the container name is within the object.
So it is not passed as a separate parameter to these methods.

Each instance contains the configuration information for that stage of the build.

B<Container::Buildah::Stage> automatically adds the I<--add-history> option so that each action will be recorded
as part of the OCI container build history.

=cut

# instantiate an object
# this should only be called by Container::Buildah - these objects will be passed to each stage's stage->func()
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
# public method
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
# public method
sub container_name
{
	my $self = shift;

	# derive container name
	if (not exists $self->{container_name}) {
		$self->{container_name} = Container::Buildah->get_config("basename")."_".$self->get_name;
	}
	return $self->{container_name};
}

#
# buildah subcommand front-end functions
# Within Container::Buildah::Stage the object has methods for subcommands which take a container name.
# Each method gets container_name from the object. So it is not passed as a separate parameter.
#
# Other more general subcommands are in Container::Buildah class.
#

# front-end to "buildah add" subcommand
# usage: $self->add( [{[dest => value]. [chown => mode]},] src, [src, ...] )
# public method
sub add
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

	# initialize argument list for buildah-add
	my @args = qw(--add-history);

	# process arguments which take a single string
	foreach my $argname (qw(chown)) {
		if (exists $params->{$argname}) {
			if (ref $params->{$argname}) {
				confess "add parameter '".$argname."' must be a scalar, got "
					.(ref $params->{$argname});
			}
			push @args, "--$argname", $params->{$argname};
			delete $params->{$argname};
		}
	}

	# error out if any unexpected parameters remain
	if (%$params) {
		confess "add received undefined parameters '".(join(" ", keys %$params));
	}

	# run command
	Container::Buildah::buildah("add", @args, $self->container_name, @paths, ($dest ? ($dest) : ()));
}

# front-end to "buildah commit" subcommand
# usage: $self->commit( [{param => value, ...}], image-name )
# public method
sub commit
{
	my $self = shift;
	my %params = @_;

	# initialize argument list for buildah-commit
	my @args;

	# TODO
	confess "unimplemented";
}


# front-end to "buildah config" subcommand
# usage: $self->config( param => value, ...)
# Note: this is for the container's configuration, not to be confused with configuration data of this module
# public method
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
# usage: $self->copy( [{dest => value},] src, [src, ...] )
# public method
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

# front-end to "buildah from" subcommand
# usage: $self->from( [{[dest => value]. [chown => mode]},] src, [src, ...] )
# public method
sub from
{
	my $self = shift;
	my %params = @_;

	# initialize argument list for buildah-from
	my @args = qw(--add-history);

	# TODO
	confess "unimplemented";
}

# front-end to "buildah mount" subcommand
# usage: $path = $self->mount()
# public method
sub mount
{
	my $self = shift;
	my %params = @_;

	# TODO
	confess "unimplemented";
}

# front-end to "buildah run" subcommand
# usage: $self->run( [{param => value, ...}], [command], ... )
# Command parameter can be an array of strings for one command, or array of arrays of strings for multiple commands.
# This applies the same command-line arguments (from %params) to each command. To change parameters for a command,
# make a separate call to the function.
# public method
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

# front-end to "buildah umount" subcommand
# usage: $self->umount()
# public method
sub umount
{
	my $self = shift;
	my %params = @_;

	# TODO
	confess "unimplemented";
}

#
# private methods - container-stage processing utilities
#

# remove a container by name if it already exists - we need the name
# private method
sub rmcontainer
{
	my $self = shift;

	Container::Buildah::cmd({name => "rmcontainer", nonzero => sub {},
		zero => sub {Container::Buildah::buildah("rm", $self->container_name);}},
		Container::Buildah::prog("buildah")." inspect ".$self->container_name.' >/dev/null 2>&1');
}

# derive tarball name for stage which produces it
# defaults to the current stage
# private method
sub tarball
{
	my $self = shift;
	my $stage_name = shift // $self->get_name;
	return Container::Buildah->get_config("basename")."_".$stage_name.".tar.bz2";
}

# generic external wrapper function for all stages
# mount the container namespace and enter it to run the custom stage build function
# private method
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
# private method
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

# drop leading slash from a path
sub dropslash
{
	my $str = shift;
	if (substr($str,0,1) eq '/') {
		substr($str,0,1) = '';
	}
	return $str;
}

# export tarball for availability to other container stages if configured
# private method
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
				push @product_dirs, dropslash($product);
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

