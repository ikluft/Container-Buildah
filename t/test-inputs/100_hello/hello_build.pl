#!/usr/bin/perl
# hello_build.pl - test Container::Buildah building and running a binary in a container
use strict;
use warnings;
use autodie;

use Carp qw(croak);
use Container::Buildah;
use File::Basename;
use Readonly;
use YAML::XS;

# directory for build stage to make its binaries, not saved for other stages
Readonly::Scalar my $build_dir => "/opt/hello-build";

# directory for build stage to save its product files, saved for runtime stage
Readonly::Scalar my $bin_dir => "/opt/hello-bin";

# input directory and YAML config file
Readonly::Scalar my $hello_src => "hello.c";
Readonly::Scalar my $hello_bin => "hello";

# container parameters
Container::Buildah::init_config(
	basename => "hello",
	added_opts => [qw(save=s inputs=s)],
	base_image => 'docker://docker.io/alpine:[% alpine_version %]',
	required_config => [qw(alpine_version)],
	hello_version => '[% timestamp_str %]', 
	stages => {
		build => {
			from => "[% base_image %]",
			func_exec => \&stage_build,
			produces => [$bin_dir],
		},
		runtime => {
			from => "[% base_image %]",
			consumes => [qw(build)],
			func_exec => \&stage_runtime,
            commit => ["[% basename %]:[% hello_version %]"],
		},
	},
);

# container-namespace code for build stage
sub stage_build
{
	my $stage = shift;
	$stage->debug({level => 1}, "start");
	my $cb = Container::Buildah->instance();
	my $hello_version = $cb->get_config('hello_version');
	my $input_dir = $cb->get_config('opts', 'inputs');

	$stage->run(
		# install dependencies
		[qw(/sbin/apk add --no-cache binutils gcc musl-dev)],

		# create build and product directories
		["mkdir", $build_dir, $bin_dir],
	);
	$stage->config({workingdir => $build_dir});
	$stage->copy({dest => $build_dir}, $input_dir."/".$hello_src);
	$stage->run(
		["gcc", "--std=c17", '-DVERSION="'.$hello_version.'"', $hello_src, "-o", "$bin_dir/$hello_bin"],
	);
}

# container-namespace code for runtime stage
sub stage_runtime
{
	my $stage = shift;
	$stage->debug({level => 1}, "start");
	my $cb = Container::Buildah->instance();
	
	# container environment
	$stage->config({
		entrypoint => $bin_dir.'/'.$hello_bin,
	});

}

#
# main
#

# run Container::Buildah mainline
my $result;
eval {
	$result = Container::Buildah::main();
};
if ($@) {
	say STDERR "exception: $@";
}
my $config = Container::Buildah->get_config();

# save configuration in YAML for test script
if (not Container::Buildah->get_config("opts", "internal")) {
	my $yaml_save = Container::Buildah->get_config("opts", "save");
	YAML::XS::DumpFile($yaml_save, $config);
}
exit ($result // 1);
