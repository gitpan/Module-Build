package Module::Build::Base;

# $Id $

use strict;
use Config;
use File::Copy ();
use File::Find ();
use File::Path ();
use File::Basename ();
use File::Spec ();
use Data::Dumper ();

sub new {
  my $package = shift;
  my %input = @_;

  my $args   = delete $input{args}   || {};
  my $config = delete $input{config} || {};

  my ($action, $cmd_args) = __PACKAGE__->cull_args(@ARGV);
  die "Too early to specify a build action '$action'.  Do 'Build $action' instead.\n"
    if $action;

  my $cmd_config;
  if ($cmd_args->{config}) {
    # XXX need to hashify this string better (deal with quoted whitespace)
    $cmd_config->{$1} = $2 while $cmd_args->{config} =~ /(\w+)=(\S+)/;
  } else {
    $cmd_config = {};
  }
  delete $cmd_args->{config};

  # Extract our 'properties' from $cmd_args, the rest are put in 'args'
  my $cmd_properties = {};
  foreach my $key (keys %$cmd_args) {
    $cmd_properties = delete $cmd_args->{$key} if __PACKAGE__->valid_property($key);
  }

  # 'args' are arbitrary user args.
  # 'config' is Config.pm and its overridden values.
  # 'properties' is stuff Module::Build needs in order to work.  They get saved in _build/.
  # Anything else in $self doesn't get saved.

  my $self = bless {
		    args => {%$args, %$cmd_args},
		    config => {%Config, %$config, %$cmd_config},
		    properties => {
				   build_script => 'Build',
				   config_dir => '_build',
				   %input,
				   %$cmd_properties,
				  },
		    new_cleanup => {},
		   }, $package;

  $self->check_manifest;
  $self->check_prereq;
  $self->find_version;
  
  $self->write_config;
  
  return $self;
}

sub resume {
  my $package = shift;
  my $self = bless {@_}, $package;
  
  $self->read_config;
  $self->{new_cleanup} = {};
  return $self;
}

{
  # XXX huge hack alert - will revisit this later
  my %valid_properties = map {$_ => 1}
    qw(
       module_name
       module_version
       module_version_from
       prereq
       config_dir
       build_script
       debugger
       verbose
       c_source
       autosplit
      );

  sub valid_property { exists $valid_properties{$_[1]} }
}

# XXX Problem - if Module::Build is loaded from a different directory,
# it'll look for (and perhaps destroy/create) a _build directory.
sub subclass {
  my ($pack, %opts) = @_;

  my $build_dir = '_build'; # XXX The _build directory is ostensibly settable by the user.  Shouldn't hard-code here.
  $pack->delete_filetree($build_dir) if -e $build_dir;

  die "Must provide 'code' or 'class' option to subclass()\n"
    unless $opts{code} or $opts{class};

  $opts{code}  ||= '';
  $opts{class} ||= 'MyModuleBuilder';
  
  my $filename = File::Spec->catfile($build_dir, 'lib', split '::', $opts{class}) . '.pm';
  my $filedir  = File::Basename::dirname($filename);
  print "Creating custom builder $filename in $filedir\n";
  
  File::Path::mkpath($filedir);
  die "Can't create directory $filedir: $!" unless -d $filedir;
  
  open my($fh), ">$filename" or die "Can't create $filename: $!";
  print $fh <<EOF;
package $opts{class};
use Module::Build;
\@ISA = qw(Module::Build);
$opts{code}
1;
EOF
  close $fh;
  
  push @INC, File::Spec->catdir($build_dir, 'lib');
  eval "use $opts{class}";
  die $@ if $@;

  return $opts{class};
}

sub find_version {
  my ($self) = @_;
  return if exists $self->{properties}{module_version};
  
  if (exists $self->{properties}{module_version_from}) {
    my $version = $self->version_from_file($self->{properties}{module_version_from});
    $self->{properties}{module_version} = $version;
    delete $self->{properties}{module_version_from};
  } else {
    # Try to find the version in 'module_name'
    my $chief_file = $self->module_name_to_file($self->{properties}{module_name});
    die "Can't find module '$self->{properties}{module_name}' for version check" unless defined $chief_file;
    $self->{properties}{module_version} = $self->version_from_file($chief_file);
  }
}

sub module_name_to_file {
  my ($self, $mod) = @_;
  my $file = File::Spec->catfile(split '::', $mod);
  foreach ('lib', @INC) {
    my $testfile = File::Spec->catfile($_, $file);
    return $testfile if -e $testfile and !-d _;  # For stuff like ExtUtils::xsubpp
    return "$testfile.pm" if -e "$testfile.pm";
  }
  return;
}

sub version_from_file {
  my ($self, $file) = @_;

  # Some of this code came from the ExtUtils:: hierarchy.
  open my($fh), $file or die "Can't open '$file' for version: $!";
  while (<$fh>) {
    if ( /([\$*])(([\w\:\']*)\bVERSION)\b.*\=/ ) {
      my $eval = qq{
		    package Module::Build::Base::_version;
		    no strict;
		    
		    local $1$2;
		    \$$2=undef; do {
		      $_
		    }; \$$2
		   };
      local $^W;
      return scalar eval $eval;
    }
  }
  return undef;
  #die "Couldn't find version string in '$file'";
}

sub add_to_cleanup {
  my $self = shift;
  @{$self->{new_cleanup}}{@_} = ();
}

sub write_cleanup {
  my ($self) = @_;
  return unless %{$self->{new_cleanup}};  # no new files
  
  # Merge the new parameters into the old
  @{ $self->{cleanup} }{ keys %{ $self->{new_cleanup} } } = ();
  
  # Write to the cleanup file
  my $cleanup_file = $self->config_file('cleanup');
  open my $fh, ">$cleanup_file" or die "Can't write '$cleanup_file': $!";
  print $fh map {"$_\n"} sort keys %{$self->{cleanup}};
}

sub config_file {
  my $self = shift;
  return File::Spec->catfile($self->{properties}{config_dir}, @_);
}

sub read_config {
  my ($self) = @_;
  
  my $file = $self->config_file('build_params');
  open my $fh, $file or die "Can't read '$file': $!";
  my $ref = eval do {local $/; <$fh>};
  die if $@;
  ($self->{args}, $self->{config}, $self->{properties}) = @$ref;
  close $fh;
  
  my $cleanup_file = $self->config_file('cleanup');
  $self->{cleanup} = {};
  if (-e $cleanup_file) {
    open my $fh, $cleanup_file or die "Can't read '$file': $!";
    my @files = <$fh>;
    chomp @files;
    @{$self->{cleanup}}{@files} = ();
  }
}

sub write_config {
  my ($self) = @_;
  
  File::Path::mkpath($self->{properties}{config_dir});
  -d $self->{properties}{config_dir} or die "Can't mkdir $self->{properties}{config_dir}: $!";
  
  my $file = $self->config_file('build_params');
  open my $fh, ">$file" or die "Can't create '$file': $!";
  local $Data::Dumper::Terse = 1;
  print $fh Data::Dumper::Dumper([$self->{args}, $self->{config}, $self->{properties}]);
  close $fh;
}

sub check_prereq {
  my $self = shift;
  return 1 unless $self->{properties}{prereq};

  my $pass = 1;
  while (my ($modname, $spec) = each %{$self->{properties}{prereq}}) {
    my $thispass = $self->check_installed_version($modname, $spec);
    warn "WARNING: $@\n" unless $thispass;
    $pass &&= $thispass;
  }

  if (!$pass) {
    warn "ERRORS FOUND IN PREREQUISITES.  You may wish to install the versions ".
         "of the modules indicated above before proceeding with this installation.\n";
  }
  return $pass;
}

sub check_installed_version {
  my ($self, $modname, $spec) = @_;

  my $file = $self->module_name_to_file($modname);
  unless ($file) {
    $@ = "Prerequisite $modname isn't installed";
    return 0;
  }

  my $version = $self->version_from_file($file);
  if ($spec and !$version) {
    $@ = "Couldn't find a \$VERSION in prerequisite '$file'";
    return 0;
  }

  my @conditions;
  if ($spec =~ /^\s*([\w.]+)\s*$/) { # A plain number, maybe with dots, letters, and underscores
    @conditions = (">= $spec");
  } else {
    @conditions = split /\s*,\s*/, $self->{properties}{prereq}{$modname};
  }

  foreach (@conditions) {
    if ($_ !~ /^\s*  (<=?|>=?|==|!=)  \s*  [\w.]+  \s*$/x) {
      $@ = "Invalid prerequisite condition for $modname: $_";
      next;
    }
    unless (eval "\$version $_") {
      $@ = "$modname version $version is installed, but we need version $_";
      return 0;
    }
  }

  return $version ? $version : '0 but true';
}

sub rm_previous_build_script {
  my $self = shift;
  if (-e $self->{properties}{build_script}) {
    print "Removing previous file '$self->{properties}{build_script}'\n";
    unlink $self->{properties}{build_script} or die "Couldn't remove '$self->{properties}{build_script}': $!";
  }
}

sub make_build_script_executable {
  chmod 0544, $_[0]->{properties}{build_script};
}

sub print_build_script {
  my ($self, $fh) = @_;
  
  my $build_package = ref($self);

  my ($config_dir, $build_script, $build_dir) = 
    ($self->{properties}{config_dir}, $self->{properties}{build_script},
     File::Spec->rel2abs(File::Basename::dirname($0)));  # XXX should be property of $self

  my @myINC = @INC;
  for ($config_dir, $build_script, $build_dir, @myINC) {
    s/([\\\'])/\\$1/g;
  }

  my $quoted_INC = join ', ', map "'$_'", @myINC;

  print $fh <<EOF;
$self->{config}{startperl} -w

BEGIN { \@INC = ($quoted_INC) }

chdir('$build_dir') or die 'Cannot chdir to $build_dir: '.\$!;
use $build_package;

# This should have just enough arguments to be able to bootstrap the rest.
my \$build = resume $build_package (
  properties => {
    config_dir => '$config_dir',
    build_script => '$build_script',
  },
);
eval {\$build->dispatch};
my \$err = \$@;
\$build->write_cleanup;  # Always write, even if error occurs
die \$err if \$err;

EOF
}

sub create_build_script {
  my ($self) = @_;
  
  $self->rm_previous_build_script;

  print("Creating new '$self->{properties}{build_script}' script for ",
	"'$self->{properties}{module_name}' version '$self->{properties}{module_version}'\n");
  open my $fh, ">$self->{properties}{build_script}" or die "Can't create '$self->{properties}{build_script}': $!";
  $self->print_build_script($fh);
  close $fh;
  
  $self->make_build_script_executable;

  return 1;
}

sub check_manifest {
  # Stolen nearly verbatim from MakeMaker.  But ExtUtils::Manifest
  # could easily be re-written into a modern Perl dialect.

  print "Checking whether your kit is complete...\n";
  require ExtUtils::Manifest;  # ExtUtils::Manifest is not warnings clean.
  local ($^W, $ExtUtils::Manifest::Quiet) = (0,1);
  
  if (my @missed = ExtUtils::Manifest::manicheck()) {
    print "Warning: the following files are missing in your kit:\n";
    print "\t", join "\n\t", @missed;
    print "\n";
    print "Please inform the author.\n";
  } else {
    print "Looks good\n";
  }
}

sub dispatch {
  my $self = shift;
  
  if (@_) {
    $self->{action} = shift;
    $self->{args} = {%{$self->{args}}, @_};
  } else {
    my ($action, $args) = $self->cull_args(@ARGV);
    $self->{action} = $action || 'build';
    $self->{args} = {%{$self->{args}}, %$args};
  }

  my $action = "ACTION_$self->{action}";
  print("No method '$action' defined.\n"), return unless $self->can($action);
  
  return $self->$action;
}

sub cull_args {
  my $self = shift;
  my ($action, %args);
  foreach (@_) {
    if ( /^(\w+)=(.*)/ ) {
      $args{$1} = $2;
    } elsif ( /^(\w+)$/ ) {
      die "Error: multiple build actions given: '$action' and '$1'" if $action;
      $action = $1;
    } else {
      die "Malformed build parameter '$_'";
    }
  }
  return ($action, \%args);
}

sub super_classes {
  my ($self, $class, $seen) = @_;
  $class ||= ref($self);
  $seen  ||= {};
  
  no strict 'refs';
  my @super = grep {not $seen->{$_}++} $class, @{ $class . '::ISA' };
  return @super, map {$self->super_classes($_,$seen)} @super;
}

sub ACTION_help {
  my ($self) = @_;

  print <<EOF;

 Usage: $0 <action> arg1=value arg2=value ...
 Example: $0 test verbose=1
 
 Actions defined:
EOF

  my %actions;
  {
    no strict 'refs';
    
    foreach my $class ($self->super_classes) {
      #print "Checking $class\n";
      foreach ( keys %{ $class . '::' } ) {
	$actions{$1}++ if /ACTION_(\w+)/;
      }
    }
  }

  my @actions = sort keys %actions;
  # Flow down columns, not across rows
  @actions = map $actions[($_ + ($_ % 2) * @actions) / 2],  0..$#actions;
  
  while (my ($one, $two) = splice @actions, 0, 2) {
    printf("  %-12s                   %-12s\n", $one, $two||'');
  }

  print "\nSee `perldoc Module::Build` for details of the individual actions.\n";
}

sub ACTION_test {
  my ($self) = @_;
  require Test::Harness;
  
  $self->depends_on('build');
  
  local $Test::Harness::switches = '-w -d' if $self->{properties}{debugger};
  local $Test::Harness::verbose = $self->{properties}{verbose} || 0;
  local $ENV{TEST_VERBOSE} = $self->{properties}{verbose} || 0;

  # Make sure we test the module in blib/
  {
    local $SIG{__WARN__} = sub {};  # shut blib.pm up
    eval "use blib";
  }
  die $@ if $@;
  
  # Find all possible tests and run them
  my @tests;
  push @tests, 'test.pl'                          if -e 'test.pl';
  push @tests, @{$self->rscan_dir('t', qr{\.t$})} if -e 't' and -d _;
  if (@tests) {
    # Work around a Test::Harness bug that loses the particular perl we're running under
    local $^X = $self->{config}{perlpath} unless $Test::Harness::VERSION gt '2.01';
    Test::Harness::runtests(@tests);
  } else {
    print("No tests defined.\n");
  }

  # This will get run and the user will see the output.  It doesn't
  # emit Test::Harness-style output.
  if (-e 'visual.pl') {
    $self->run_script('visual.pl', '-Mblib');
  }
}

sub ACTION_testdb {
  my ($self) = @_;
  local $self->{properties}{debugger} = 1;
  $self->depends_on('test');
}

sub ACTION_build {
  my ($self) = @_;
  
  if ($self->{properties}{c_source}) {
    push @{$self->{include_dirs}}, $self->{properties}{c_source};
    my $files = $self->rscan_dir($self->{properties}{c_source}, qr{\.(c|PL)$});
    foreach my $file (@$files) {
      if ($file =~ /c$/) {
	push @{$self->{objects}}, $self->compile_c($file);
      } elsif ($file =~ /PL/) {
	$self->run_perl_script($file);
      }
    }
  }

  # What more needs to be done when creating blib/ from lib/?
  # Currently we handle .pm, .xs, .pod, and .PL files.
  my $files = $self->rscan_dir('lib', qr{\.(pm|pod|xs|PL)$});
  $self->lib_to_blib($files, 'blib');
  $self->add_to_cleanup('blib');
}

sub ACTION_install {
  my ($self) = @_;
  require ExtUtils::Install;
  $self->depends_on('build');
  ExtUtils::Install::install($self->install_map('blib'), 1, 0);
}

sub ACTION_fakeinstall {
  my ($self) = @_;
  require ExtUtils::Install;
  $self->depends_on('build');
  ExtUtils::Install::install($self->install_map('blib'), 1, 1);
}

sub ACTION_clean {
  my ($self) = @_;
  foreach my $item (keys %{$self->{cleanup}}, keys %{$self->{new_cleanup}}) {
    $self->delete_filetree($item);
  }
}

sub ACTION_realclean {
  my ($self) = @_;
  $self->depends_on('clean');
  $self->delete_filetree($self->{properties}{config_dir}, $self->{properties}{build_script});
}

sub ACTION_dist {
  my ($self) = @_;
  
  $self->depends_on('distdir');
  
  my $dist_dir = $self->dist_dir;
  
  $self->make_tarball($dist_dir);
  $self->delete_filetree($dist_dir);
}

sub ACTION_distcheck {
  my ($self) = @_;
  
  require ExtUtils::Manifest;
  local $^W; # ExtUtils::Manifest is not warnings clean.
  ExtUtils::Manifest::fullcheck();
}

sub ACTION_skipcheck {
  my ($self) = @_;
  
  require ExtUtils::Manifest;
  local $^W; # ExtUtils::Manifest is not warnings clean.
  ExtUtils::Manifest::skipcheck();
}

sub ACTION_distclean {
  my ($self) = @_;
  
  $self->depends('realclean');
  $self->depends('distcheck');
}

sub ACTION_distdir {
  my ($self) = @_;
  
  my $dist_dir = $self->dist_dir;
  
  require ExtUtils::Manifest;  # ExtUtils::Manifest is not warnings clean.
  local ($^W, $ExtUtils::Manifest::Quiet) = (0,1);
  
  my $dist_files = ExtUtils::Manifest::maniread('MANIFEST');
  ExtUtils::Manifest::manicopy($dist_files, $dist_dir, 'best');
}

sub ACTION_disttest {
  my ($self) = @_;

  $self->depends_on('distdir');

  my $dist_dir = $self->dist_dir;
  chdir $dist_dir or die "Cannot chdir to $dist_dir: $!";
  # XXX could be different names for scripts
  $self->do_system("$^X Build.PL") or die "Error executing '$^X Build.PL' in dist directory: $!";
  $self->do_system('./Build') or die "Error executing './Build' in dist directory: $!";
  $self->do_system('./Build test') or die "Error executing './Build test' in dist directory: $!";
  # XXX doesn't change back to top dir
}

sub ACTION_manifest {
  my ($self) = @_;
  
  require ExtUtils::Manifest;  # ExtUtils::Manifest is not warnings clean.
  local ($^W, $ExtUtils::Manifest::Quiet) = (0,1);
  ExtUtils::Manifest::mkmanifest();
}

sub dist_dir {
  my ($self) = @_;

  (my $dist_dir = $self->{properties}{module_name}) =~ s/::/-/;
  return "$dist_dir-$self->{properties}{module_version}";
}

sub make_tarball {
  my ($self, $dir) = @_;
  
  require Archive::Tar;
  my $files = $self->rscan_dir($dir);
  print "Creating $dir.tar.gz\n";
  Archive::Tar->create_archive("$dir.tar.gz", 1, @$files);
}

sub install_map {
  my ($self, $blib) = @_;
  my $lib  = File::Spec->catfile($blib,'lib');
  my $arch = File::Spec->catfile($blib,'arch');
  return {$lib  => $self->{config}{sitelib},
	  $arch => $self->{config}{sitearch},
	  read  => ''};  # To keep ExtUtils::Install quiet
}

sub depends_on {
  my $self = shift;
  foreach my $action (@_) {
    my $method = "ACTION_$action";
    $self->$method;
  }
}

sub rscan_dir {
  my ($self, $dir, $pattern) = @_;
  my @result;
  my $subr = $pattern ? sub {push @result, $File::Find::name if /$pattern/}
                      : sub {push @result, $File::Find::name};
  File::Find::find({wanted => $subr, no_chdir => 1}, $dir);
  return \@result;
}

sub delete_filetree {
  my $self = shift;
  foreach (@_) {
    next unless -e $_;
    print "Deleting $_\n";
    if (-d $_) {
      File::Path::rmtree($_, 0, 0);
    } else {
      unlink $_;
    }
    die "Couldn't remove '$_': $!\n" if -e $_;
  }
}

sub lib_to_blib {
  my ($self, $files, $to) = @_;
  
  # Create $to/arch to keep blib.pm happy (what a load of hooie!)
  File::Path::mkpath( File::Spec->catdir($to, 'arch') );

  if ($self->{properties}{autosplit}) {
    $self->autosplit_file($self->{properties}{autosplit}, $to);
  }
  
  foreach my $file (@$files) {
    if ($file =~ /\.p(m|od)$/) {
      # No processing needed
      $self->copy_if_modified($file, $to);

    } elsif ($file =~ /\.xs$/) {
      $self->process_xs($file);

    } elsif ($file =~ /\.PL$/) {
      $self->run_perl_script($file);

    } else {
      warn "Ignoring file '$file', unknown extension\n";
    }
  }

}

sub autosplit_file {
  my ($self, $file, $to) = @_;
  require AutoSplit;
  my $dir = File::Spec->catdir($to, 'lib', 'auto');
  AutoSplit::autosplit($file, $dir);
}

sub compile_c {
  my ($self, $file) = @_;
  my $cf = $self->{config}; # For convenience

  # File name, minus the suffix
  (my $file_base = $file) =~ s/\.[^.]+$//;
  my $obj_file = "$file_base$cf->{obj_ext}";
  return $obj_file if $self->up_to_date($file, $obj_file);
  
  $self->add_to_cleanup($obj_file);
  my $coredir = File::Spec->catdir($cf->{archlib}, 'CORE');
  my $include_dirs = $self->{include_dirs} ? join ' ', map {"-I$_"} @{$self->{include_dirs}} : '';
  $self->do_system("$cf->{cc} $include_dirs -c $cf->{ccflags} -I$coredir -o $obj_file $file")
    or die "error building $cf->{dlext} file from '$file'";

  return $obj_file;
}

sub run_perl_script {
  my ($self, $script, $preargs, $postargs) = @_;
  $preargs ||= '';   $postargs ||= '';
  return $self->do_system("$self->{config}{perlpath} $preargs $script $postargs");
}

# A lot of this looks Unixy, but actually it may work fine on Windows.
# I'll see what people tell me about their results.
sub process_xs {
  my ($self, $file) = @_;
  my $cf = $self->{config}; # For convenience

  # File name, minus the suffix
  (my $file_base = $file) =~ s/\.[^.]+$//;

  # .xs -> .c
  unless ($self->up_to_date($file, "$file_base.c")) {
    $self->add_to_cleanup("$file_base.c");
    
    my $xsubpp  = $self->module_name_to_file('ExtUtils::xsubpp')
      or die "Can't find ExtUtils::xsubpp in INC (@INC)";
    my $typemap =  $self->module_name_to_file('ExtUtils::typemap');
    
    # XXX the '> $file_base.c' isn't really a post-arg, it's redirection.  Fix later.
    $self->run_perl_script($xsubpp, "-I$cf->{archlib} -I$cf->{privlib}", 
			   "-noprototypes -typemap '$typemap' $file > $file_base.c")
      or die "error building .c file from '$file'";
  }
  
  # .c -> .o
  $self->compile_c("$file_base.c");

  # The .bs and .a files don't go in blib/lib/, they go in blib/arch/auto/.
  # Unfortunately we have to pre-compute the whole path.
  my $archdir;
  {
    my @dirs = File::Spec->splitdir($file_base);
    $archdir = File::Spec->catdir('blib','arch','auto', @dirs[1..$#dirs]);
  }
  
  # .xs -> .bs
  unless ($self->up_to_date($file, "$file_base.bs")) {
    $self->add_to_cleanup("$file_base.bs");
    require ExtUtils::Mkbootstrap;
    print "ExtUtils::Mkbootstrap::Mkbootstrap('$file_base')\n";
    ExtUtils::Mkbootstrap::Mkbootstrap($file_base);  # Original had $BSLOADLIBS - what's that?
    {open my $fh, ">> $file_base.bs"}  # touch
  }
  $self->copy_if_modified("$file_base.bs", $archdir, 1);
  
  # .o -> .(a|bundle)
  my $lib_file = File::Spec->catfile($archdir, File::Basename::basename("$file_base.$cf->{dlext}"));
  unless ($self->up_to_date("$file_base$cf->{obj_ext}", $lib_file)) {
    my $linker_flags = $cf->{extra_linker_flags} || '';
    my $objects = $self->{objects} || [];
    $self->do_system("$cf->{shrpenv} $cf->{cc} $cf->{lddlflags} -o $lib_file ".
		     "$file_base$cf->{obj_ext} @$objects $linker_flags")
      or die "error building $file_base$cf->{obj_ext} from '$file_base.$cf->{dlext}'";
  }
}

sub do_system {
  my ($self, $cmd, $silent) = @_;
  print "$cmd\n" unless $silent;
  return !system($cmd);
}

sub copy_if_modified {
  my ($self, $file, $to, $flatten) = @_;

  my $to_path;
  if ($flatten) {
    my $basename = File::Basename::basename($file);
    $to_path = File::Spec->catfile($to, $basename);
  } else {
    $to_path = File::Spec->catfile($to, $file);
  }
  return if -e $to_path and -M $to_path < -M $file;  # Already fresh
  
  # Create parent directories
  File::Path::mkpath(File::Basename::dirname($to_path), 0, 0777);
  
  print "$file -> $to_path\n";
  File::Copy::copy($file, $to_path) or die "Can't copy('$file', '$to_path'): $!";
}

sub up_to_date {
  my ($self, $source, $derived) = @_;
  my @source  = ref($source)  ? @$source  : ($source);
  my @derived = ref($derived) ? @$derived : ($derived);

  return 0 if grep {not -e} @derived;

  my $most_recent_source = time / (24*60*60);
  foreach my $file (@source) {
    $most_recent_source = -M $file if -M $file < $most_recent_source;
  }
  
  foreach my $file (@derived) {
    return 0 if -M $file > $most_recent_source;
  }
  return 1;
}


#sub is_newer_than {
#  my ($self, $one, $two) = @_;
#  return 1 unless -e $two;
#  return 0 unless -e $one;
#  return -M $one < -M $two;
#}

1;
__END__


=head1 NAME

Module::Build::Base - Default methods for Module::Build

=head1 SYNOPSIS

  please see the Module::Build documentation

=head1 DESCRIPTION

The C<Module::Build::Base> module defines the core functionality of
C<Module::Build>.  Its methods may be overridden by any of the
platform-independent modules in the C<Module::Build::Platform::>
namespace, but the intention here is to make this base module as
platform-neutral as possible.  Nicely enough, Perl has several core
tools available in the C<File::> namespace for doing this, so the task
isn't very difficult.

Please see the C<Module::Build> documentation for more details.

=head1 AUTHOR

Ken Williams, ken@forum.swarthmore.edu

=head1 SEE ALSO

perl(1), Module::Build(3)

=cut
