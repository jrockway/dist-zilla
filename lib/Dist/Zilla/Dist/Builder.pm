package Dist::Zilla::Dist::Builder;
# ABSTRACT: dist zilla subclass for building dists
use Moose 0.92; # role composition fixes
extends 'Dist::Zilla';

use Moose::Autobox 0.09; # ->flatten
use MooseX::Types::Moose qw(HashRef);
use MooseX::Types::Path::Class qw(Dir File);

use Archive::Tar;
use File::pushd ();
use Path::Class;

use namespace::autoclean;

=method from_config

  my $zilla = Dist::Zilla->from_config(\%arg);

This routine returns a new Zilla from the configuration in the current working
directory.

This method should not be relied upon, yet.  Its semantics are B<certain> to
change.

Valid arguments are:

  config_class - the class to use to read the config
                 default: Dist::Zilla::MVP::Reader::Finder

=cut

sub from_config {
  my ($class, $arg) = @_;
  $arg ||= {};

  my $root = dir($arg->{dist_root} || '.');

  my $sequence = $class->_load_config({
    root   => $root,
    chrome => $arg->{chrome},
    config_class    => $arg->{config_class},
    _global_stashes => $arg->{_global_stashes},
  });

  my $self = $sequence->section_named('_')->zilla;

  $self->_setup_default_plugins;

  return $self;
}

sub _setup_default_plugins {
  my ($self) = @_;
  unless ($self->plugin_named(':InstallModules')) {
    require Dist::Zilla::Plugin::FinderCode;
    my $plugin = Dist::Zilla::Plugin::FinderCode->new({
      plugin_name => ':InstallModules',
      zilla       => $self,
      style       => 'grep',
      code        => sub { local $_ = $_->name; m{\Alib/} and m{\.(pm|pod)$} },
    });

    $self->plugins->push($plugin);
  }

  unless ($self->plugin_named(':TestFiles')) {
    require Dist::Zilla::Plugin::FinderCode;
    my $plugin = Dist::Zilla::Plugin::FinderCode->new({
      plugin_name => ':TestFiles',
      zilla       => $self,
      style       => 'grep',
      code        => sub { local $_ = $_->name; m{\At/} },
    });

    $self->plugins->push($plugin);
  }

  unless ($self->plugin_named(':ExecFiles')) {
    require Dist::Zilla::Plugin::FinderCode;
    my $plugin = Dist::Zilla::Plugin::FinderCode->new({
      plugin_name => ':ExecFiles',
      zilla       => $self,
      style       => 'list',
      code        => sub {
        my $plugins = $_[0]->zilla->plugins_with(-ExecFiles);
        my @files = map {; @{ $_->find_files } } @$plugins;

        return \@files;
      },
    });

    $self->plugins->push($plugin);
  }

  unless ($self->plugin_named(':ShareFiles')) {
    require Dist::Zilla::Plugin::FinderCode;
    my $plugin = Dist::Zilla::Plugin::FinderCode->new({
      plugin_name => ':ShareFiles',
      zilla       => $self,
      style       => 'list',
      code        => sub {
        my $map = $self->zilla->_share_dir_map;
        my @files;
        if ( $map->{dist} ) {
          push @files, $self->zilla->files->grep(sub {
            local $_ = $_->name; m{\A\Q$map->{dist}\E/}
          });
        }
        if ( my $mod_map = $map->{module} ) {
          for my $mod ( keys %$mod_map ) {
            push @files, $self->zilla->files->grep(sub {
              local $_ = $_->name; m{\A\Q$mod_map->{$mod}\E/}
            });
          }
        }
        return \@files;
      },
    });

    $self->plugins->push($plugin);
  }
}

has _share_dir_map => (
  is   => 'ro',
  isa  => HashRef,
  init_arg  => undef,
  lazy      => 1,
  builder   => '_build_share_dir_map',
);

sub _build_share_dir_map {
  my ($self) = @_;

  my $share_dir_map = {};

  for my $plugin ( $self->plugins_with(-ShareDir)->flatten ) {
    next unless my $sub_map = $plugin->share_dir_map;

    if ( $sub_map->{dist} ) {
      $self->log_fatal("can't install more than one distribution ShareDir")
        if $share_dir_map->{dist};
      $share_dir_map->{dist} = $sub_map->{dist};
    }

    if ( my $mod_map = $sub_map->{module} ) {
      for my $mod ( keys %$mod_map ) {
        $self->log_fatal("can't install more than one ShareDir for $mod")
          if $share_dir_map->{module}{$mod};
        $share_dir_map->{module}{$mod} = $mod_map->{$mod};
      }
    }
  }

  return $share_dir_map;
}


sub _load_config {
  my ($class, $arg) = @_;
  $arg ||= {};

  my $config_class =
    $arg->{config_class} ||= 'Dist::Zilla::MVP::Reader::Finder';

  Class::MOP::load_class($config_class);

  $arg->{chrome}->logger->log_debug(
    { prefix => '[DZ] ' },
    "reading configuration using $config_class"
  );

  my $root = $arg->{root};

  require Dist::Zilla::MVP::Assembler::Zilla;
  require Dist::Zilla::MVP::Section;
  my $assembler = Dist::Zilla::MVP::Assembler::Zilla->new({
    chrome        => $arg->{chrome},
    zilla_class   => $class,
    section_class => 'Dist::Zilla::MVP::Section', # make this DZMA default
  });

  for ($assembler->sequence->section_named('_')) {
    $_->add_value(chrome => $arg->{chrome});
    $_->add_value(root   => $arg->{root});
    $_->add_value(_global_stashes => $arg->{_global_stashes})
      if $arg->{_global_stashes};
  }

  my $seq = $config_class->read_config(
    $root->file('dist'),
    {
      assembler => $assembler
    },
  );

  return $seq;
}

=method build_in

  $zilla->build_in($root);

This method builds the distribution in the given directory.  If no directory
name is given, it defaults to DistName-Version.  If the distribution has
already been built, an exception will be thrown.

=method build

This method just calls C<build_in> with no arguments.  It gets you the default
behavior without the weird-looking formulation of C<build_in> with no object
for the preposition!

=cut

sub build { $_[0]->build_in }

sub build_in {
  my ($self, $root) = @_;

  $self->log_fatal("tried to build with a minter")
    if $self->isa('Dist::Zilla::Dist::Minter');

  $self->log_fatal("attempted to build " . $self->name . " a second time")
    if $self->built_in;

  $_->before_build for $self->plugins_with(-BeforeBuild)->flatten;

  $self->log("beginning to build " . $self->name);

  $_->gather_files     for $self->plugins_with(-FileGatherer)->flatten;
  $_->prune_files      for $self->plugins_with(-FilePruner)->flatten;
  $_->munge_files      for $self->plugins_with(-FileMunger)->flatten;

  $_->register_prereqs for $self->plugins_with(-PrereqSource)->flatten;

  $self->prereqs->finalize;

  # Barf if someone has already set up a prereqs entry? -- rjbs, 2010-04-13
  $self->distmeta->{prereqs} = $self->prereqs->as_string_hash;

  $_->setup_installer for $self->plugins_with(-InstallTool)->flatten;

  $self->_check_dupe_files;

  my $build_root = $self->_prep_build_root($root);

  $self->log("writing " . $self->name . " in $build_root");

  for my $file ($self->files->flatten) {
    $self->_write_out_file($file, $build_root);
  }

  $_->after_build({ build_root => $build_root })
    for $self->plugins_with(-AfterBuild)->flatten;

  $self->built_in($build_root);
}

=attr built_in

This is the L<Path::Class::Dir>, if any, in which the dist has been built.

=cut

has built_in => (
  is   => 'rw',
  isa  => Dir,
  init_arg  => undef,
);

=method ensure_built_in

  $zilla->ensure_built_in($root);

This method behaves like C<L</build_in>>, but if the dist is already built in
C<$root> (or the default root, if no root is given), no exception is raised.

=method ensure_built_in

This method just calls C<ensure_built_in> with no arguments.  It gets you the
default behavior without the weird-looking formulation of C<ensure_built_in>
with no object for the preposition!

=cut

sub ensure_built {
  $_[0]->ensure_built_in;
}

sub ensure_built_in {
  my ($self, $root) = @_;

  # $root ||= $self->name . q{-} . $self->version;
  return $self->built_in if $self->built_in and
    (!$root or ($self->built_in eq $root));

  Carp::croak("dist is already built, but not in $root") if $self->built_in;
  $self->build_in($root);
}

=method build_archive

  $zilla->build_archive;

This method will ensure that the dist has been built, and will then build a
tarball of the build directory in the current directory.

=cut

sub build_archive {
  my ($self, $file) = @_;

  my $built_in = $self->ensure_built;

  my $archive = Archive::Tar->new;

  $_->before_archive for $self->plugins_with(-BeforeArchive)->flatten;

  my %seen_dir;
  for my $distfile ($self->files->flatten) {
    my $in = file($distfile->name)->dir;
    $archive->add_files( $built_in->subdir($in) ) unless $seen_dir{ $in }++;
    $archive->add_files( $built_in->file( $distfile->name ) );
  }

  ## no critic
  $file ||= file(join(q{},
    $self->name,
    '-',
    $self->version,
    ($self->is_trial ? '-TRIAL' : ''),
    '.tar.gz',
  ));

  # Fix up the CHMOD on the archived files, to inhibit 'withoutworldwritables'
  # behaviour on win32.
  for my $f ( $archive->get_files ) {
    $f->mode( $f->mode & ~022 );
  }

  $self->log("writing archive to $file");
  $archive->write("$file", 9);

  return $file;
}

sub _prep_build_root {
  my ($self, $build_root) = @_;

  my $default_name = $self->name . q{-} . $self->version;
  $build_root = dir($build_root || $default_name);

  $build_root->mkpath unless -d $build_root;

  my $dist_root = $self->root;

  $build_root->rmtree if -d $build_root;

  return $build_root;
}

=method release

  $zilla->release;

This method releases the distribution, probably by uploading it to the CPAN.
The actual effects of this method (as with most of the methods) is determined
by the loaded plugins.

=cut

sub release {
  my $self = shift;

  Carp::croak("you can't release without any Releaser plugins")
    unless my @releasers = $self->plugins_with(-Releaser)->flatten;

  my $tgz = $self->build_archive;

  # call all plugins implementing BeforeRelease role
  $_->before_release($tgz) for $self->plugins_with(-BeforeRelease)->flatten;

  # do the actual release
  $_->release($tgz) for @releasers;

  # call all plugins implementing AfterRelease role
  $_->after_release($tgz) for $self->plugins_with(-AfterRelease)->flatten;
}

=method clean

This method removes temporary files and directories suspected to have been
produced by the Dist::Zilla build process.  Specifically, it deletes the
F<.build> directory and any entity that starts with the dist name and a hyphen,
like matching the glob C<Your-Dist-*>.

=cut

sub clean {
  my ($self) = @_;

  require File::Path;
  for my $x (grep { -e } '.build', glob($self->name . '-*')) {
    $self->log("clean: removing $x");
    File::Path::rmtree($x);
  };
}

=method install

  $zilla->install( \%arg );

This method installs the distribution locally.  The distribution will be built
in a temporary subdirectory, then the process will change directory to that
subdir and an installer will be run.

Valid arguments are:

  install_command - the command to run in the subdir to install the dist
                    default (roughly): $^X -MCPAN -einstall .

                    this argument should be an arrayref

=cut

sub install {
  my ($self, $arg) = @_;
  $arg ||= {};

  require File::Temp;

  my $build_root = dir('.build');
  $build_root->mkpath unless -d $build_root;

  my $target = dir( File::Temp::tempdir(DIR => $build_root) );
  $self->log("building distribution under $target for installation");
  $self->ensure_built_in($target);

  eval {
    ## no critic Punctuation
    my $wd = File::pushd::pushd($target);
    my @cmd = $arg->{install_command}
            ? @{ $arg->{install_command} }
            : ($^X => '-MCPAN' =>
                $^O eq 'MSWin32' ? q{-e"install '.'"} : '-einstall "."');

    $self->log_debug([ 'installing via %s', \@cmd ]);
    system(@cmd) && $self->log_fatal([ "error running %s", \@cmd ]);
  };

  if ($@) {
    $self->log($@);
    $self->log("left failed dist in place at $target");
  } else {
    $self->log("all's well; removing $target");
    $target->rmtree;
  }

  return;
}

=method test

  $zilla->test;

This method builds a new copy of the distribution and tests it using
C<L</run_tests_in>>.

=cut

sub test {
  my ($self) = @_;

  Carp::croak("you can't test without any TestRunner plugins")
    unless my @testers = $self->plugins_with(-TestRunner)->flatten;

  require File::Temp;

  my $build_root = dir('.build');
  $build_root->mkpath unless -d $build_root;

  my $target = dir( File::Temp::tempdir(DIR => $build_root) );
  $self->log("building test distribution under $target");

  local $ENV{AUTHOR_TESTING} = 1;
  local $ENV{RELEASE_TESTING} = 1;

  $self->ensure_built_in($target);

  my $error = $self->run_tests_in($target);

  $self->log("all's well; removing $target");
  $target->rmtree;
}

=method run_tests_in

  my $error = $zilla->run_tests_in($directory);

This method runs the tests in $directory (a Path::Class::Dir), which
must contain an already-built copy of the distribution.  It will throw an
exception if there are test failures.

It does I<not> set any of the C<*_TESTING> environment variables, nor
does it clean up C<$directory> afterwards.

=cut

sub run_tests_in {
  my ($self, $target) = @_;

  Carp::croak("you can't test without any TestRunner plugins")
    unless my @testers = $self->plugins_with(-TestRunner)->flatten;

  for my $tester (@testers) {
    my $wd = File::pushd::pushd($target);
    $tester->test( $target );
  }
}

=method run_in_build

  $zilla->run_in_build( \@cmd );

This method makes a temporary directory, builds the distribution there,
executes the dist's first L<BuildRunner|Dist::Zilla::Role::BuildRunner>, and
then runs the given command in the build directory.  If the command exits
non-zero, the directory will be left in place.

=cut

sub run_in_build {
  my ($self, $cmd) = @_;

  # The sort below is a cheap hack to get ModuleBuild ahead of
  # ExtUtils::MakeMaker. -- rjbs, 2010-01-05
  $self->log_fatal("you can't build without any BuildRunner plugins")
    unless my @builders =
    $self->plugins_with(-BuildRunner)->sort->reverse->flatten;

  require "Config.pm"; # skip autoprereq
  require File::Temp;

  # dzil-build the dist
  my $build_root = dir('.build');
  $build_root->mkpath unless -d $build_root;

  my $target    = dir( File::Temp::tempdir(DIR => $build_root) );
  my $abstarget = $target->absolute;
  $self->log("building test distribution under $target");

  $self->ensure_built_in($target);

  # building the dist for real
  my $ok = eval {
    my $wd = File::pushd::pushd($target);
    $builders[0]->build;
    local $ENV{PERL5LIB} =
      join $Config::Config{path_sep},
      map { $abstarget->subdir('blib', $_) } qw{ arch lib };
    system(@$cmd) and die "error while running: @$cmd";
    1;
  };

  if ($ok) {
    $self->log("all's well; removing $target");
    $target->rmtree;
  } else {
    my $error = $@ || '(unknown error)';
    $self->log($error);
    $self->log_fatal("left failed dist in place at $target");
  }
}

__PACKAGE__->meta->make_immutable;
1;
