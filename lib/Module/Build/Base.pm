package Module::Build::Base;

use strict;
BEGIN { require 5.00503 }
use Config;
use File::Copy ();
use File::Find ();
use File::Path ();
use File::Basename ();
use File::Spec ();
use File::Compare ();
use Data::Dumper ();
use IO::File ();

#################### Constructors ###########################
sub new {
  my $self = shift()->_construct(@_);

  $self->cull_args(@ARGV);
  
  die "Too early to specify a build action '$self->{action}'.  Do 'Build $self->{action}' instead.\n"
    if $self->{action};

  $self->_set_install_paths;
  $self->dist_name;
  $self->check_manifest;
  $self->check_prereq;
  $self->dist_version;

  return $self;
}

sub resume {
  my $self = shift()->_construct(@_);
  
  $self->read_config;
  
  my $perl = $self->find_perl_interpreter;
  warn(" * WARNING: Configuration was initially created with '$self->{properties}{perl}',\n".
       "   but we are now using '$perl'.\n")
    unless $perl eq $self->{properties}{perl};
  
  my $mb_version = Module::Build->VERSION;
  die(" * ERROR: Configuration was initially created with Module::Build version '$self->{properties}{mb_version}',\n".
      "   but we are now using version '$mb_version'.  Please re-run the Build.PL or Makefile.PL script.\n")
    unless $mb_version eq $self->{properties}{mb_version};
  
  $self->cull_args(@ARGV);
  $self->{action} ||= 'build';
  
  return $self;
}

sub new_from_context {
  my ($package, %args) = @_;
  
  # XXX Read the META.yml and see whether we need to run the Build.PL
  
  # Run the Build.PL
  $package->run_perl_script('Build.PL');
  my $self = $package->resume;
  $self->merge_args(%args);
  return $self;
}

sub current {
  # hmm, wonder what the right thing to do here is
  local @ARGV;
  return shift()->resume;
}

sub _construct {
  my ($package, %input) = @_;

  my $args   = delete $input{args}   || {};
  my $config = delete $input{config} || {};

  # The following warning could be unnecessary if the user is running
  # an embedded perl, but there aren't too many of those around, and
  # embedded perls aren't usually used to install modules, and the
  # installation process sometimes needs to run external scripts
  # (e.g. to run tests).
  my $perl = $package->find_perl_interpreter
    or warn "Warning: Can't locate your perl binary";

  my $self = bless {
		    args => {%$args},
		    config => {%Config, %$config},
		    properties => {
				   build_script    => 'Build',
				   base_dir        => $package->cwd,
				   config_dir      => '_build',
				   blib            => 'blib',
				   requires        => {},
				   recommends      => {},
				   build_requires  => {},
				   conflicts       => {},
				   perl            => $perl,
				   mb_version      => Module::Build->VERSION,
				   build_elements  => [qw( PL support pm xs pod script )],
				   install_types   => [qw( lib arch script bindoc libdoc )],
				   installdirs     => 'site',
				   include_dirs    => [],
				   %input,
				  },
		   }, $package;

  my ($p, $c) = ($self->{properties}, $self->{config});
  $p->{bindoc_dirs} ||= [ "$p->{blib}/script" ];
  $p->{libdoc_dirs} ||= [ "$p->{blib}/lib", "$p->{blib}/arch" ];

  # Synonyms
  $p->{requires} = delete $p->{prereq} if exists $p->{prereq};
  $p->{script_files} = delete $p->{scripts} if exists $p->{scripts};

  $self->add_to_cleanup( @{delete $p->{add_to_cleanup}} )
    if $p->{add_to_cleanup};

  # perl 5.8.1-RC[1-3] had some broken %Config entries, and
  # unfortunately Red Hat 9 shipped it like that.  Fix 'em up here.
  for (qw(siteman1 siteman3 vendorman1 vendorman3)) {
    $c->{"install${_}dir"} ||= $c->{"install${_}"};
  }
  
  return $self;
}

################## End constructors #########################

sub _set_install_paths {
  my $self = shift;
  my $c = $self->{config};

  $self->{properties}{install_sets} =
    {
     core   => {
		lib     => $c->{installprivlib},
		arch    => $c->{installarchlib},
		bin     => $c->{installbin},
		script  => $c->{installscript},
		bindoc  => $c->{installman1dir},
		libdoc  => $c->{installman3dir},
	       },
     site   => {
		lib     => $c->{installsitelib},
		arch    => $c->{installsitearch},
		bin     => $c->{installsitebin} || $c->{installbin},
		script  => $c->{installsitescript} || $c->{installsitebin} || $c->{installscript},
		bindoc  => $c->{installsiteman1dir} || $c->{installman1dir},
		libdoc  => $c->{installsiteman3dir} || $c->{installman3dir},
	       },
     vendor => {
		lib     => $c->{installvendorlib},
		arch    => $c->{installvendorarch},
		bin     => $c->{installvendorbin} || $c->{installbin},
		script  => $c->{installvendorscript} || $c->{installvendorbin} || $c->{installscript},
		bindoc  => $c->{installvendorman1dir} || $c->{installman1dir},
		libdoc  => $c->{installvendorman3dir} || $c->{installman3dir},
	       },
    };
}

sub cwd {
  require Cwd;
  return Cwd::cwd();
}

sub find_perl_interpreter {
  my $perl;
  File::Spec->file_name_is_absolute($perl = $^X)
    or -f ($perl = $Config::Config{perlpath})
    or ($perl = $^X);
  return $perl;
}

sub base_dir { shift()->{properties}{base_dir} }
sub installdirs { shift()->{properties}{installdirs} }

sub prompt {
  my $self = shift;
  my ($mess, $def) = @_;
  die "prompt() called without a prompt message" unless @_;

  my $INTERACTIVE = -t STDIN && (-t STDOUT || !(-f STDOUT || -c STDOUT)) ;   # Pipe?
  
  ($def, my $dispdef) = defined $def ? ($def, "[$def] ") : ('', ' ');

  {
    local $|=1;
    print "$mess $dispdef";
  }
  my $ans;
  if ($INTERACTIVE) {
    $ans = <STDIN>;
    if ( defined $ans ) {
      chomp $ans;
    } else { # user hit ctrl-D
      print "\n";
    }
  }
  
  unless (defined($ans) and length($ans)) {
    print "$def\n";
    $ans = $def;
  }
  
  return $ans;
}

sub y_n {
  my $self = shift;
  die "y_n() called without a prompt message" unless @_;
  
  my $answer;
  while (1) {
    $answer = $self->prompt(@_);
    return 1 if $answer =~ /^y/i;
    return 0 if $answer =~ /^n/i;
    print "Please answer 'y' or 'n'.\n";
  }
}

sub notes {
  my $self = shift;
  return $self->_persistent_hash_read('notes') unless @_;
  
  my $key = shift;
  return $self->_persistent_hash_read('notes', $key) unless @_;
  
  my $value = shift;
  return $self->_persistent_hash_write('notes', { $key => $value });
}

{
  # XXX huge hack alert - will revisit this later
  my %valid_properties = map {$_ => 1}
    qw(
       module_name
       dist_name
       dist_version
       dist_version_from
       dist_author
       dist_abstract
       requires
       recommends
       license
       pm_files
       xs_files
       pod_files
       PL_files
       scripts
       script_files
       test_files
       perl
       config_dir
       blib
       build_script
       build_elements
       install_types
       install_sets
       install_path
       install_base
       installdirs
       destdir
       debugger
       verbose
       c_source
       autosplit
       create_makefile_pl
       create_readme
       pollute
       include_dirs
       bindoc_dirs
       libdoc_dirs
      );

  sub valid_property { exists $valid_properties{$_[1]} }

  # Create an accessor for each property that doesn't already have one
  foreach my $property (keys %valid_properties) {
      next if __PACKAGE__->can($property);
      no strict 'refs';
      *{$property} = sub {
          my $self = shift;
          $self->{properties}{$property} = shift if @_;
          return $self->{properties}{$property};
      };
  }
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
  
  my $fh = IO::File->new("> $filename") or die "Can't create $filename: $!";
  print $fh <<EOF;
package $opts{class};
use Module::Build;
\@ISA = qw(Module::Build);
$opts{code}
1;
EOF
  close $fh;
  
  push @INC, File::Spec->catdir(File::Spec->rel2abs($build_dir), 'lib');
  eval "use $opts{class}";
  die $@ if $@;

  return $opts{class};
}

sub dist_name {
  my $self = shift;
  my $p = $self->{properties};
  return $p->{dist_name} if exists $p->{dist_name};
  
  die "Can't determine distribution name, must supply either 'dist_name' or 'module_name' parameter"
    unless $p->{module_name};
  
  ($p->{dist_name} = $p->{module_name}) =~ s/::/-/g;
  
  return $p->{dist_name};
}

sub dist_version {
  my ($self) = @_;
  my $p = $self->{properties};
  
  return $p->{dist_version} if exists $p->{dist_version};
  
  if (exists $p->{module_name}) {
    $p->{dist_version_from} ||= join( '/', 'lib', split '::', $p->{module_name} ) . '.pm';
  }
  
  die ("Can't determine distribution version, must supply either 'dist_version',\n".
       "'dist_version_from', or 'module_name' parameter")
    unless $p->{dist_version_from};
  
  my $version_from = File::Spec->catfile( split '/', $p->{dist_version_from} );
  
  return $p->{dist_version} = $self->version_from_file($version_from);
}

sub dist_author {
  my $self = shift;
  my $p = $self->{properties};
  
  $self->_pod_parse('author');
  $p->{dist_author} = [ $p->{dist_author} ] unless ref $p->{dist_author};

  return $p->{dist_author};
}

sub dist_abstract { shift->_pod_parse('abstract') }

sub _pod_parse {
  my ($self, $part) = @_;
  my $p = $self->{properties};
  my $member = "dist_$part";
  return $p->{$member} if exists $p->{$member};
  
  return unless $p->{dist_version_from};
  my $fh = IO::File->new($p->{dist_version_from}) or return;
  
  require Module::Build::PodParser;
  my $parser = Module::Build::PodParser->new(fh => $fh);
  my $method = "get_$part";
  return $p->{$member} = $parser->$method();
}

sub find_module_by_name {
  my ($self, $mod, $dirs) = @_;
  my $file = File::Spec->catfile(split '::', $mod);
  foreach (@$dirs) {
    my $testfile = File::Spec->catfile($_, $file);
    return $testfile if -e $testfile and !-d _;  # For stuff like ExtUtils::xsubpp
    return "$testfile.pm" if -e "$testfile.pm";
  }
  return;
}

sub _next_code_line {
  my ($self, $fh, $pat) = @_;
  my $inpod = 0;
  
  local $_;
  while (<$fh>) {
    $inpod = /^=(?!cut)/ ? 1 : /^=cut/ ? 0 : $inpod;
    next if $inpod || /^\s*#/;
    return wantarray ? ($_, /$pat/) : $_
      if $_ =~ $pat;
  }
  return;
}

sub version_from_file {
  my ($self, $file) = @_;

  # Some of this code came from the ExtUtils:: hierarchy.
  my $fh = IO::File->new($file) or die "Can't open '$file' for version: $!";

  my $match = qr/([\$*])(([\w\:\']*)\bVERSION)\b.*\=/;
  my ($v_line, $sigil, $var) = $self->_next_code_line($fh, $match) or return undef;

  my $eval = qq{q#  Hide from _packages_inside()
		 #; package Module::Build::Base::_version;
		 no strict;
		    
		 local $sigil$var;
		 \$$var=undef; do {
		   $v_line
		 }; \$$var
		};
  local $^W;
  my $result = eval $eval;
  warn "Error evaling version line '$eval' in $file: $@\n" if $@;
  return $result;
}

sub _persistent_hash_write {
  my ($self, $name, $href) = @_;
  $href ||= {};
  my $ph = $self->{phash}{$name} ||= {disk => {}, new => {}};
  
  @{$ph->{new}}{ keys %$href } = values %$href;  # Merge

  # Do some optimization to avoid unnecessary writes
  foreach my $key (keys %{ $ph->{new} }) {
    next if ref $ph->{new}{$key};
    next if ref $ph->{disk}{$key} or !exists $ph->{disk}{$key};
    delete $ph->{new}{$key} if $ph->{new}{$key} eq $ph->{disk}{$key};
  }
  
  if (my $file = $self->config_file($name)) {
    return if -e $file and !keys %{ $ph->{new} };  # Nothing to do
    
    @{$ph->{disk}}{ keys %{$ph->{new}} } = values %{$ph->{new}};  # Merge
    $self->_write_dumper($name, $ph->{disk});
    
    $ph->{new} = {};
  }
  return $self->_persistent_hash_read($name);
}

sub _persistent_hash_read {
  my $self = shift;
  my $name = shift;
  my $ph = $self->{phash}{$name} ||= {disk => {}, new => {}};

  if (@_) {
    # Return 1 key as a scalar
    my $key = shift;
    return $ph->{new}{$key} if exists $ph->{new}{$key};
    return $ph->{disk}{$key};
  } else {
    # Return all data
    my $out = (keys %{$ph->{new}}
	       ? {%{$ph->{disk}}, %{$ph->{new}}}
	       : $ph->{disk});
    return wantarray ? %$out : $out;
  }
}

sub _persistent_hash_restore {
  my ($self, $name) = @_;
  my $ph = $self->{phash}{$name} ||= {disk => {}, new => {}};
  
  my $file = $self->config_file($name) or die "No config file '$name'";
  my $fh = IO::File->new("< $file") or die "Can't read $file: $!";
  
  $ph->{disk} = eval do {local $/; <$fh>};
  die $@ if $@;
}

sub add_to_cleanup {
  my $self = shift;
  my %files = map {$_, 1} @_;
  $self->_persistent_hash_write('cleanup', \%files);
}

sub cleanup {
  my $self = shift;
  my $all = $self->_persistent_hash_read('cleanup');
  return keys %$all;
}

sub config_file {
  my $self = shift;
  return unless -d $self->config_dir;
  return File::Spec->catfile($self->config_dir, @_);
}

sub read_config {
  my ($self) = @_;
  
  my $file = $self->config_file('build_params');
  my $fh = IO::File->new($file) or die "Can't read '$file': $!";
  my $ref = eval do {local $/; <$fh>};
  die if $@;
  ($self->{args}, $self->{config}, $self->{properties}) = @$ref;
  close $fh;

  for ('cleanup', 'notes') {
    next unless -e $self->config_file($_);
    $self->_persistent_hash_restore($_);
  }
}

sub _write_dumper {
  my ($self, $filename, $data) = @_;
  
  my $file = $self->config_file($filename);
  my $fh = IO::File->new("> $file") or die "Can't create '$file': $!";
  local $Data::Dumper::Terse = 1;
  print $fh Data::Dumper::Dumper($data);
}

sub write_config {
  my ($self) = @_;
  
  File::Path::mkpath($self->{properties}{config_dir});
  -d $self->{properties}{config_dir} or die "Can't mkdir $self->{properties}{config_dir}: $!";
  
  my @items = qw(requires build_requires conflicts recommends);
  $self->_write_dumper('prereqs', { map { $_, $self->$_() } @items });
  $self->_write_dumper('build_params', [$self->{args}, $self->{config}, $self->{properties}]);

  $self->_persistent_hash_write($_) foreach qw(notes cleanup);
}

sub config         { shift()->{config} }

sub requires       { shift()->{properties}{requires} }
sub recommends     { shift()->{properties}{recommends} }
sub build_requires { shift()->{properties}{build_requires} }
sub conflicts      { shift()->{properties}{conflicts} }

sub prereq_failures {
  my $self = shift;

  my @types = qw(requires recommends build_requires conflicts);
  my $out;

  foreach my $type (@types) {
    while ( my ($modname, $spec) = each %{$self->$type()} ) {
      my $status = $self->check_installed_status($modname, $spec);
      
      if ($type eq 'conflicts') {
	next if !$status->{ok};
	$status->{conflicts} = delete $status->{need};
	$status->{message} = "Installed version '$status->{have}' of $modname conflicts with this distribution";

      } elsif ($type eq 'recommends') {
	next if $status->{ok};
	$status->{message} = ($status->{have} eq '<none>'
			      ? "Optional prerequisite $modname isn't installed"
			      : "Version $status->{have} of $modname is installed, but we prefer to have $spec");
      } else {
	next if $status->{ok};
      }

      $out->{$type}{$modname} = $status;
    }
  }

  return $out;
}

sub check_prereq {
  my $self = shift;

  my $failures = $self->prereq_failures;
  return 1 unless $failures;
  
  foreach my $type (qw(requires build_requires conflicts recommends)) {
    next unless $failures->{$type};
    my $prefix = $type eq 'recommends' ? '' : 'ERROR: ';
    while (my ($module, $status) = each %{$failures->{$type}}) {
      warn " * $prefix$status->{message}\n";
    }
  }
  
  warn "ERRORS/WARNINGS FOUND IN PREREQUISITES.  You may wish to install the versions\n".
       " of the modules indicated above before proceeding with this installation.\n\n";
  return 0;
}

sub perl_version {
  my ($self) = @_;
  # Check the current perl interpreter
  # It's much more convenient to use $] here than $^V, but 'man
  # perlvar' says I'm not supposed to.  Bloody tyrant.
  return $^V ? $self->perl_version_to_float(sprintf "%vd", $^V) : $];
}

sub perl_version_to_float {
  my ($self, $version) = @_;
  $version =~ s/\./../;
  $version =~ s/\.(\d+)/sprintf '%03d', $1/eg;
  return $version;
}

sub _parse_conditions {
  my ($self, $spec) = @_;

  if ($spec =~ /^\s*([\w.]+)\s*$/) { # A plain number, maybe with dots, letters, and underscores
    return (">= $spec");
  } else {
    return split /\s*,\s*/, $spec;
  }
}

sub check_installed_status {
  my ($self, $modname, $spec) = @_;
  my %status = (need => $spec);
  
  if ($modname eq 'perl') {
    $status{have} = $self->perl_version;
  
  } elsif (eval { $status{have} = $modname->VERSION }) {
    # Don't try to load if it's already loaded
    
  } else {
    my $file = $self->find_module_by_name($modname, \@INC);
    unless ($file) {
      @status{ qw(have message) } = ('<none>', "Prerequisite $modname isn't installed");
      return \%status;
    }
    
    $status{have} = $self->version_from_file($file);
    if ($spec and !$status{have}) {
      @status{ qw(have message) } = (undef, "Couldn't find a \$VERSION in prerequisite $modname");
      return \%status;
    }
  }
  
  my @conditions = $self->_parse_conditions($spec);
  
  foreach (@conditions) {
    my ($op, $version) = /^\s*  (<=?|>=?|==|!=)  \s*  ([\w.]+)  \s*$/x
      or die "Invalid prerequisite condition '$_' for $modname";
    
    $version = $self->perl_version_to_float($version)
      if $modname eq 'perl';
    
    next if $op eq '>=' and !$version;  # Module doesn't have to actually define a $VERSION
    
    unless ($self->compare_versions( $status{have}, $op, $version )) {
      $status{message} = "Version $status{have} of $modname is installed, but we need version $op $version";
      return \%status;
    }
  }
  
  $status{ok} = 1;
  return \%status;
}

sub compare_versions {
  my $self = shift;
  my ($v1, $op, $v2) = @_;

  # for alpha versions - this doesn't cover all cases, but should work for most:
  $v1 =~ s/_(\d+)\z/$1/;
  $v2 =~ s/_(\d+)\z/$1/;

  my $eval_str = "\$v1 $op \$v2";
  my $result   = eval $eval_str;
  warn "error comparing versions: '$eval_str' $@" if $@;

  return $result;
}

# I wish I could set $! to a string, but I can't, so I use $@
sub check_installed_version {
  my ($self, $modname, $spec) = @_;
  
  my $status = $self->check_installed_status($modname, $spec);
  
  if ($status->{ok}) {
    return $status->{have} if $status->{have} and $status->{have} ne '<none>';
    return '0 but true';
  }
  
  $@ = $status->{message};
  return 0;
}

sub make_executable {
  # Perl's chmod() is mapped to useful things on various non-Unix
  # platforms, so we use it in the base class even though it looks
  # Unixish.

  my $self = shift;
  foreach (@_) {
    my $current_mode = (stat $_)[2];
    chmod $current_mode | 0111, $_;
  }
}

sub _startperl { shift()->{config}{startperl} }

sub print_build_script {
  my ($self, $fh) = @_;
  
  my $build_package = ref($self);
  
  my %q = map {$_, $self->$_()} qw(config_dir base_dir);

  my @myINC = @INC;
  for (@myINC, values %q) {
    $_ = File::Spec->canonpath( File::Spec->rel2abs($_) );
    s/([\\\'])/\\$1/g;
  }

  my $quoted_INC = join ",\n", map "     '$_'", @myINC;
  my $shebang = $self->_startperl;

  print $fh <<EOF;
$shebang

use strict;
use Cwd;
use File::Spec;

BEGIN {
  \$^W = 1;  # Use warnings
  my \$curdir = File::Spec->canonpath( Cwd::cwd() );
  unless (\$curdir eq '$q{base_dir}') {
    die ('This script must be run from $q{base_dir}, not '."\$curdir\\n".
	 "Please re-run the Build.PL script here.\\n");
  }
  \@INC = 
    (
$quoted_INC
    );
}

use $build_package;

if (-e 'Build.PL' and not $build_package->up_to_date("Build.PL", \$0)) {
   warn "Warning: Build.PL has been altered.  You may need to run 'perl Build.PL' again.\n";
}

# This should have just enough arguments to be able to bootstrap the rest.
my \$build = $build_package->resume (
  properties => {
    config_dir => '$q{config_dir}',
  },
);

\$build->dispatch;
EOF
}

sub create_build_script {
  my ($self) = @_;
  my $p = $self->{properties};
  
  $self->write_config;
  
  if ( $self->delete_filetree($p->{build_script}) ) {
    print "Removed previous script '$p->{build_script}'\n";
  }

  print("Creating new '$p->{build_script}' script for ",
	"'$p->{dist_name}' version '$p->{dist_version}'\n");
  my $fh = IO::File->new(">$p->{build_script}") or die "Can't create '$p->{build_script}': $!";
  $self->print_build_script($fh);
  close $fh;
  
  $self->make_executable($p->{build_script});

  return 1;
}

sub check_manifest {
  return unless -e 'MANIFEST';
  
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
  local $self->{_completed_actions} = {};

  if (@_) {
    my ($action, %p) = @_;
    my $args = $p{args} ? delete($p{args}) : {};
    
    local $self->{args} = {%{$self->{args}}, %$args};
    local $self->{properties} = {%{$self->{properties}}, %p};
    return $self->_call_action($action);
  }

  die "No build action specified" unless $self->{action};
  $self->_call_action($self->{action});
}

sub _call_action {
  my ($self, $action) = @_;
  return if $self->{_completed_actions}{$action}++;
  local $self->{action} = $action;
  my $method = "ACTION_$action";
  die "No action '$action' defined, try running the 'help' action.\n" unless $self->can($method);
  return $self->$method();
}

sub _read_arg {
  my ($self, $args, $key, $val) = @_;

  if ( exists $args->{$key} ) {
    $args->{$key} = [ $args->{$key} ] unless ref $args->{$key};
    push @{$args->{$key}}, $val;
  } else {
    $args->{$key} = $val;
  }
}

sub read_args {
  my $self = shift;
  my ($action, %args, @argv);
  while (@_) {
    local $_ = shift;
    if ( /^(\w+)=(.*)/ ) {
      $self->_read_arg(\%args, $1, $2);
    } elsif ( /^--(\w+)$/ ) {
      $self->_read_arg(\%args, $1, shift());
    } elsif ( /^(\w+)$/ and !defined($action)) {
      $action = $1;
    } else {
      push @argv, $_;
    }
  }
  $args{ARGV} = \@argv;

  # 'config' and 'install_path' are additive by hash key
  my %additive = map {$_, 1} qw(config install_path);

  # Hashify these parameters
  for (keys %additive) {
    next unless exists $args{$_};
    my %hash;
    $args{$_} ||= [];
    $args{$_} = [ $args{$_} ] unless ref $args{$_};
    foreach my $arg ( @{$args{$_}} ) {
      $arg =~ /(\w+)=(.+)/
	or die "Malformed '$_' argument: '$arg' should be something like 'foo=bar'";
      $hash{$1} = $2;
    }
    $args{$_} = \%hash;
  }
  
  return \%args, $action;
}

sub merge_args {
  my ($self, $action, %args) = @_;
  my %additive = (config => $self->{config},
		  install_path => $self->{properties}{install_path} ||= {});

  $self->{action} = $action if defined $action;

  # Extract our 'properties' from $cmd_args, the rest are put in 'args'.
  while (my ($key, $val) = each %args) {
    my $add_to = ($additive{$key} ? $additive{$key}
		  : $self->valid_property($key) ? $self->{properties}
		  : $self->{args});

    if ($additive{$key}) {
      $add_to->{$_} = $val->{$_} foreach keys %$val;
    } else {
      $add_to->{$key} = $val;
    }
  }
}


sub cull_args {
  my $self = shift;
  my ($args, $action) = $self->read_args(@_);
  $self->merge_args($action, %$args);
}

sub super_classes {
  my ($self, $class, $seen) = @_;
  $class ||= ref($self) || $self;
  $seen  ||= {};
  
  no strict 'refs';
  my @super = grep {not $seen->{$_}++} $class, @{ $class . '::ISA' };
  return @super, map {$self->super_classes($_,$seen)} @super;
}

sub known_actions {
  my ($self) = @_;

  my %actions;
  no strict 'refs';
  
  foreach my $class ($self->super_classes) {
    foreach ( keys %{ $class . '::' } ) {
      $actions{$1}++ if /^ACTION_(\w+)/;
    }
  }

  return wantarray ? sort keys %actions : \%actions;
}

sub get_action_docs {
  my ($self, $action, $actions) = @_;
  $actions ||= $self->known_actions;
  $@ = '';
  ($@ = "No known action '$action'\n"), return
    unless $actions->{$action};
  
  my ($files_found, @docs) = (0);
  foreach my $class ($self->super_classes) {
    (my $file = $class) =~ s{::}{/}g;
    $file = $INC{$file . '.pm'} or next;
    my $fh = IO::File->new("< $file") or next;
    $files_found++;
    
    # Code below modified from /usr/bin/perldoc
    
    # Skip to ACTIONS section
    local $_;
    while (<$fh>) {
      last if /^=head1 ACTIONS\s/;
    }
    
    # Look for our action
    my ($found, $inlist) = (0, 0);
    while (<$fh>) {
      if (/^=item\s+\Q$action\E\b/)  {
	$found = 1;
      } elsif (/^=(item|back)/) {
	last if $found > 1 and not $inlist;
      }
      next unless $found;
      push @docs, $_;
      ++$inlist if /^=over/;
      --$inlist if /^=back/;
      ++$found  if /^\w/; # Found descriptive text
    }
  }

  unless ($files_found) {
    $@ = "Couldn't find any documentation to search";
    return;
  }
  unless (@docs) {
    $@ = "Couldn't find any docs for action '$action'";
    return;
  }
  
  return join '', @docs;
}

sub ACTION_help {
  my ($self) = @_;
  my $actions = $self->known_actions;
  
  if (@{$self->{args}{ARGV}}) {
    my $msg = $self->get_action_docs($self->{args}{ARGV}[0], $actions) || "$@\n";
    print $msg;
    return;
  }

  print <<EOF;

 Usage: $0 <action> arg1=value arg2=value ...
 Example: $0 test verbose=1
 
 Actions defined:
EOF

  # Flow down columns, not across rows
  my @actions = sort keys %$actions;
  @actions = map $actions[($_ + ($_ % 2) * @actions) / 2],  0..$#actions;
  
  while (my ($one, $two) = splice @actions, 0, 2) {
    printf("  %-12s                   %-12s\n", $one, $two||'');
  }
  
  print "\nRun `Build help <action>` for details on an individual action.\n";
  print "See `perldoc Module::Build` for complete documentation.\n";
}

sub ACTION_test {
  my ($self) = @_;
  my $p = $self->{properties};
  require Test::Harness;
  
  $self->depends_on('code');
  
  # Do everything in our power to work with all versions of Test::Harness
  my @harness_switches = $p->{debugger} ? qw(-w -d) : ();
  local $Test::Harness::switches    = join ' ', grep defined, $Test::Harness::switches, @harness_switches;
  local $Test::Harness::Switches    = join ' ', grep defined, $Test::Harness::Switches, @harness_switches;
  local $ENV{HARNESS_PERL_SWITCHES} = join ' ', grep defined, $ENV{HARNESS_PERL_SWITCHES}, @harness_switches;
  
  $Test::Harness::switches = undef   unless length $Test::Harness::switches;
  $Test::Harness::Switches = undef   unless length $Test::Harness::Switches;
  delete $ENV{HARNESS_PERL_SWITCHES} unless length $ENV{HARNESS_PERL_SWITCHES};
  
  local ($Test::Harness::verbose,
	 $Test::Harness::Verbose,
	 $ENV{TEST_VERBOSE},
         $ENV{HARNESS_VERBOSE}) = ($p->{verbose} || 0) x 4;

  # Make sure we test the module in blib/
  local @INC = (File::Spec->catdir($p->{base_dir}, $self->blib, 'lib'),
		File::Spec->catdir($p->{base_dir}, $self->blib, 'arch'),
		@INC);
  
  my $tests = $self->find_test_files;

  if (@$tests) {
    # Work around a Test::Harness bug that loses the particular perl we're running under
    local $^X = $p->{perl} unless $Test::Harness::VERSION gt '2.01';
    Test::Harness::runtests(@$tests);
  } else {
    print("No tests defined.\n");
  }

  # This will get run and the user will see the output.  It doesn't
  # emit Test::Harness-style output.
  if (-e 'visual.pl') {
    $self->run_perl_script('visual.pl', '-Mblib');
  }
}

sub test_files {
  my $self = shift;
  my $p = $self->{properties};
  if (@_) {
    return $p->{test_files} = (@_ == 1 ? shift : [@_]);
  }
  return $self->find_test_files;
}

sub expand_test_dir {
  my ($self, $dir) = @_;
  return @{$self->rscan_dir($dir, qr{\.t$})} if $self->{properties}{recursive_test_files};
  return sort glob File::Spec->catfile($dir, "*.t");
}

sub ACTION_testdb {
  my ($self) = @_;
  local $self->{properties}{debugger} = 1;
  $self->depends_on('test');
}

sub ACTION_code {
  my ($self) = @_;
  
  # All installable stuff gets created in blib/ .
  # Create blib/arch to keep blib.pm happy
  my $blib = $self->blib;
  $self->add_to_cleanup($blib);
  File::Path::mkpath( File::Spec->catdir($blib, 'arch') );
  
  $self->autosplit_file($self->autosplit, $blib) if $self->autosplit;
  
  foreach my $element (@{$self->build_elements}) {
    my $method = "process_${element}_files";
    $self->$method();
  }
}

sub ACTION_build {
  my $self = shift;
  $self->depends_on('code');
  $self->depends_on('docs');
}

sub process_support_files {
  my $self = shift;
  my $p = $self->{properties};
  return unless $p->{c_source};
  
  push @{$p->{include_dirs}}, $p->{c_source};
  
  my $files = $self->rscan_dir($p->{c_source}, qr{\.c(pp)?$});
  foreach my $file (@$files) {
    push @{$p->{objects}}, $self->compile_c($file);
  }
}

sub process_PL_files {
  my ($self) = @_;
  my $files = $self->find_PL_files;
  
  while (my ($file, $to) = each %$files) {
    local $ENV{'PERL5LIB'} = join $self->{config}{path_sep}, @INC;
    unless ($self->up_to_date( $file, $to )) {
      $self->run_perl_script($file, [], [@$to]);
      $self->add_to_cleanup(@$to);
    }
  }
}

sub process_xs_files {
  my $self = shift;
  my $files = $self->find_xs_files;
  while (my ($from, $to) = each %$files) {
    unless ($from eq $to) {
      $self->add_to_cleanup($to);
      $self->copy_if_modified( from => $from, to => $to );
    }
    $self->process_xs($to);
  }
}

sub process_pod_files {
  my $self = shift;
  my $files = $self->find_pod_files;
  while (my ($file, $dest) = each %$files) {
    $self->copy_if_modified(from => $file, to => File::Spec->catfile($self->blib, $dest) );
  }
}

sub process_pm_files {
  my $self = shift;
  my $files = $self->find_pm_files;
  while (my ($file, $dest) = each %$files) {
    $self->copy_if_modified(from => $file, to => File::Spec->catfile($self->blib, $dest) );
  }
}

sub process_script_files {
  my $self = shift;
  my $files = $self->find_script_files;
  return unless keys %$files;

  my $script_dir = File::Spec->catdir($self->blib, 'script');
  File::Path::mkpath( $script_dir );
  
  foreach my $file (keys %$files) {
    my $result = $self->copy_if_modified($file, $script_dir, 'flatten') or next;
    $self->fix_shebang_line($result);
    $self->make_executable($result);
  }
}

sub find_PL_files {
  my $self = shift;
  if (my $files = $self->{properties}{PL_files}) {
    # 'PL_files' is given as a Unix file spec, so we localize_file_path().
    
    if (UNIVERSAL::isa($files, 'ARRAY')) {
      return { map {$_, [/^(.*)\.PL$/]}
	       map $self->localize_file_path($_),
	       @$files };

    } elsif (UNIVERSAL::isa($files, 'HASH')) {
      my %out;
      while (my ($file, $to) = each %$files) {
	$out{ $self->localize_file_path($file) } = [ map $self->localize_file_path($_),
						     ref $to ? @$to : ($to) ];
      }
      return \%out;

    } else {
      die "'PL_files' must be a hash reference or array reference";
    }
  }
  
  return unless -d 'lib';
  return { map {$_, [/^(.*)\.PL$/]} @{ $self->rscan_dir('lib', qr{\.PL$}) } };
}

sub find_pm_files  { shift->_find_file_by_type('pm',  'lib') }
sub find_pod_files { shift->_find_file_by_type('pod', 'lib') }
sub find_xs_files  { shift->_find_file_by_type('xs',  'lib') }

sub find_script_files {
  my $self = shift;
  if (my $files = $self->script_files) {
    # Always given as a Unix file spec.  Values in the hash are
    # meaningless, but we preserve if present.
    return { map {$self->localize_file_path($_), $files->{$_}} keys %$files };
  }
  
  # No default location for script files
  return {};
}

sub find_test_files {
  my $self = shift;
  my $p = $self->{properties};
  
  if (my $files = $p->{test_files}) {
    $files = [keys %$files] if UNIVERSAL::isa($files, 'HASH');
    $files = [map { -d $_ ? $self->expand_test_dir($_) : $_ }
	      map glob,
	      $self->split_like_shell($files)];
    
    # Always given as a Unix file spec.  Values in the hash are
    # meaningless, but we preserve if present.
    return [ map $self->localize_file_path($_), @$files ];
    
  } else {
    # Find all possible tests in t/ or test.pl
    my @tests;
    push @tests, 'test.pl'                          if -e 'test.pl';
    push @tests, $self->expand_test_dir('t')        if -e 't' and -d _;
    return \@tests;
  }
}

sub _find_file_by_type {
  my ($self, $type, $dir) = @_;
  
  if (my $files = $self->{properties}{"${type}_files"}) {
    # Always given as a Unix file spec
    return { map $self->localize_file_path($_), %$files };
  }
  
  return {} unless -d $dir;
  return { map {$_, $_}
	   map $self->localize_file_path($_),
	   @{ $self->rscan_dir($dir, qr{\.$type$}) } };
}

sub localize_file_path {
  my ($self, $path) = @_;
  return $path unless $path =~ m{/};
  return File::Spec->catfile( split qr{/}, $path );
}

sub fix_shebang_line { # Adapted from fixin() in ExtUtils::MM_Unix 1.35
  my ($self, @files) = @_;
  my $c = $self->{config};
  
  my ($does_shbang) = $c->{sharpbang} =~ /^\s*\#\!/;
  for my $file (@files) {
    my $FIXIN = IO::File->new($file) or die "Can't process '$file': $!";
    local $/ = "\n";
    chomp(my $line = <$FIXIN>);
    next unless $line =~ s/^\s*\#!\s*//;     # Not a shbang file.
    
    my ($cmd, $arg) = (split(' ', $line, 2), '');
    next unless $cmd =~ /perl/i;
    my $interpreter = $self->{properties}{perl};
    
    print STDOUT "Changing sharpbang in $file to $interpreter" if $self->{verbose};
    my $shb = '';
    $shb .= "$c->{sharpbang}$interpreter $arg\n" if $does_shbang;
    
    # I'm not smart enough to know the ramifications of changing the
    # embedded newlines here to \n, so I leave 'em in.
    $shb .= qq{
eval 'exec $interpreter $arg -S \$0 \${1+"\$\@"}'
    if 0; # not running under some shell
} unless $self->os_type eq 'Windows'; # this won't work on win32, so don't
    
    my $FIXOUT = IO::File->new(">$file.new")
      or die "Can't create new $file: $!\n";
    
    # Print out the new #! line (or equivalent).
    local $\;
    undef $/; # Was localized above
    print $FIXOUT $shb, <$FIXIN>;
    close $FIXIN;
    close $FIXOUT;
    
    rename($file, "$file.bak")
      or die "Can't rename $file to $file.bak: $!";
    
    rename("$file.new", $file)
      or die "Can't rename $file.new to $file: $!";
    
    unlink "$file.bak"
      or warn "Couldn't clean up $file.bak, leaving it there";
    
    $self->do_system($c->{eunicefix}, $file) if $c->{eunicefix} ne ':';
  }
}


sub ACTION_docs {
  my $self = shift;
  $self->depends_on('code');
  require Pod::Man;
  $self->manify_bin_pods() if $self->install_destination('bindoc');
  $self->manify_lib_pods() if $self->install_destination('libdoc');
}

sub manify_bin_pods {
  my $self    = shift;
  my $parser  = Pod::Man->new( section => 1 ); # binary manpages go in section 1
  my $files   = $self->_find_pods($self->{properties}{bindoc_dirs});
  return unless keys %$files;
  
  my $mandir = File::Spec->catdir( $self->blib, 'bindoc' );
  File::Path::mkpath( $mandir, 0, 0777 );

  foreach my $file (keys %$files) {
    my $manpage = $self->man1page_name( $file ) . '.' . $self->{config}{man1ext};
    my $outfile = File::Spec->catfile( $mandir, $manpage);
    next if $self->up_to_date( $file, $outfile );
    print "Manifying $file -> $outfile\n";
    $parser->parse_from_file( $file, $outfile );
    $files->{$file} = $outfile;
  }
}

sub manify_lib_pods {
  my $self    = shift;
  my $parser  = Pod::Man->new( section => 3 ); # library manpages go in section 3
  my $files   = $self->_find_pods($self->{properties}{libdoc_dirs});
  return unless keys %$files;
  
  my $mandir = File::Spec->catdir( $self->blib, 'libdoc' );
  File::Path::mkpath( $mandir, 0, 0777 );

  while (my ($file, $relfile) = each %$files) {
    my $manpage = $self->man3page_name( $relfile ) . '.' . $self->{config}{man3ext};
    my $outfile = File::Spec->catfile( $mandir, $manpage);
    next if $self->up_to_date( $file, $outfile );
    print "Manifying $file -> $outfile\n";
    $parser->parse_from_file( $file, $outfile );
    $files->{$file} = $outfile;
  }
}

sub _find_pods {
  my ($self, $dirs) = @_;
  my %files;
  foreach my $spec (@$dirs) {
    my $dir = $self->localize_file_path($spec);
    next unless -e $dir;
    do { $files{$_} = File::Spec->abs2rel($_, $dir) if $self->contains_pod( $_ ) }
      for @{ $self->rscan_dir( $dir ) };
  }
  return \%files;
}

sub contains_pod {
  my ($self, $file) = @_;
  return '' unless -T $file;  # Only look at text files
  
  my $fh = IO::File->new( $file ) or die "Can't open $file: $!";
  while (my $line = <$fh>) {
    return 1 if $line =~ /^\=(?:head|pod|item)/;
  }
  
  return '';
}

# Adapted from ExtUtils::MM_Unix
sub man1page_name {
  my $self = shift;
  return File::Basename::basename( shift );
}

# Adapted from ExtUtils::MM_Unix and Pod::Man
# Depending on M::B's dependency policy, it might make more sense to refactor
# Pod::Man::begin_pod() to extract a name() methods, and use them...
#    -spurkis
sub man3page_name {
  my $self = shift;
  my ($vol, $dirs, $file) = File::Spec->splitpath( shift );
  my @dirs = File::Spec->splitdir( File::Spec->canonpath($dirs) );
  
  # Remove known exts from the base name
  $file =~ s/\.p(?:od|m|l)\z//i;
  
  return join( $self->manpage_separator, @dirs, $file );
}

sub manpage_separator {
  return '::';
}

# For systems that don't have 'diff' executable, should use Algorithm::Diff
sub ACTION_diff {
  my $self = shift;
  $self->depends_on('build');
  my $local_lib = File::Spec->rel2abs('lib');
  my @myINC = grep {$_ ne $local_lib} @INC;
  my @flags = @{$self->{args}{ARGV}};
  @flags = $self->split_like_shell($self->{args}{flags} || '') unless @flags;
  
  my $installmap = $self->install_map;
  delete $installmap->{read};
  delete $installmap->{write};

  my $text_suffix = qr{\.(pm|pod)$};

  while (my $localdir = each %$installmap) {
    my $files = $self->rscan_dir($localdir, sub {-f});
    
    foreach my $file (@$files) {
      my @parts = File::Spec->splitdir($file);
      my @localparts = File::Spec->splitdir($localdir);
      @parts = @parts[@localparts .. $#parts]; # Get rid of blib/lib or similar
      
      my $installed = $self->find_module_by_name(join('::', @parts), \@myINC);
      if (not $installed) {
	print "Only in lib: $file\n";
	next;
      }
      
      my $status = File::Compare::compare($installed, $file);
      next if $status == 0;  # Files are the same
      die "Can't compare $installed and $file: $!" if $status == -1;
      
      if ($file =~ $text_suffix) {
	$self->do_system('diff', @flags, $installed, $file);
      } else {
	print "Binary files $file and $installed differ\n";
      }
    }
  }
}

sub ACTION_install {
  my ($self) = @_;
  require ExtUtils::Install;
  $self->depends_on('build');
  ExtUtils::Install::install($self->install_map, 1, 0, $self->{args}{uninst}||0);
}

sub ACTION_fakeinstall {
  my ($self) = @_;
  require ExtUtils::Install;
  $self->depends_on('build');
  ExtUtils::Install::install($self->install_map, 1, 1, $self->{args}{uninst}||0);
}

sub ACTION_versioninstall {
  my ($self) = @_;
  
  die "You must have only.pm 0.25 or greater installed for this operation: $@\n"
    unless eval { require only; 'only'->VERSION(0.25); 1 };
  
  $self->depends_on('build');
  
  my %onlyargs = map {exists($self->{args}{$_}) ? ($_ => $self->{args}{$_}) : ()}
    qw(version versionlib);
  only::install::install(%onlyargs);
}

sub ACTION_clean {
  my ($self) = @_;
  foreach my $item ($self->cleanup) {
    $self->delete_filetree($item);
  }
}

sub ACTION_realclean {
  my ($self) = @_;
  $self->depends_on('clean');
  $self->delete_filetree($self->config_dir, $self->build_script);
}

sub ACTION_ppd {
  my ($self) = @_;
  require Module::Build::PPMMaker;
  my $ppd = Module::Build::PPMMaker->new();
  my $file = $ppd->make_ppd(%{$self->{args}}, build => $self);
  $self->add_to_cleanup($file);
}

sub ACTION_ppmdist {
  my ($self) = @_;
  
  $self->depends_on('build', 'ppd');
  $self->add_to_cleanup($self->ppm_name);
  $self->make_tarball($self->{properties}{blib}, $self->ppm_name);
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

sub _sign_dir {
  my ($self, $dir) = @_;

  unless (eval { require Module::Signature; 1 }) {
    warn "Couldn't load Module::Signature for 'distsign' action:\n $@\n";
    return;
  }
  
  # Add SIGNATURE to the MANIFEST
  {
    my $manifest = File::Spec->catfile($dir, 'MANIFEST');
    die "Signing a distribution requires a MANIFEST file" unless -e $manifest;
    my $mode = (stat $manifest)[2];
    chmod($mode | 0222, $manifest) or die "Can't make $manifest writable: $!";
    
    my $fh = IO::File->new(">> $manifest") or die "Can't add SIGNATURE to $manifest: $!";
    print $fh "\nSIGNATURE    Added here by Module::Build\n";
    close $fh;
    chmod($mode, $manifest);
  }
  
  # We protect the signing with an eval{} to make sure we get back to
  # the right directory after a signature failure.  Would be nice if
  # Module::Signature took a directory argument.
  
  my $start_dir = $self->cwd;
  chdir $dir or die "Can't chdir() to $dir: $!";
  eval {local $Module::Signature::Quiet = 1; Module::Signature::sign()};
  my @err = $@ ? ($@) : ();
  chdir $start_dir or push @err, "Can't chdir() back to $start_dir: $!";
  die join "\n", @err if @err;
}

sub ACTION_distsign {
  my ($self) = @_;
  {
    local $self->{properties}{sign} = 0;  # We'll sign it ourselves
    $self->depends_on('distdir') unless -d $self->dist_dir;
  }
  $self->_sign_dir($self->dist_dir);
}

sub ACTION_skipcheck {
  my ($self) = @_;
  
  require ExtUtils::Manifest;
  local $^W; # ExtUtils::Manifest is not warnings clean.
  ExtUtils::Manifest::skipcheck();
}

sub ACTION_distclean {
  my ($self) = @_;
  
  $self->depends_on('realclean');
  $self->depends_on('distcheck');
}

sub do_create_makefile_pl {
  my $self = shift;
  require Module::Build::Compat;
  Module::Build::Compat->create_makefile_pl($self->create_makefile_pl, $self, @_);
}

sub do_create_readme {
  my $self = shift;
  require Pod::Text;
  my $parser = Pod::Text->new;
  $parser->parse_from_file($self->dist_version_from, 'README', @_);
}

sub ACTION_distdir {
  my ($self) = @_;

  $self->depends_on('distmeta');

  $self->do_create_makefile_pl if $self->create_makefile_pl;
  $self->do_create_readme if $self->create_readme;
  
  my $dist_files = $self->_read_manifest('MANIFEST');
  delete $dist_files->{SIGNATURE};  # Don't copy, create a fresh one
  unless (keys %$dist_files) {
    warn "No files found in MANIFEST - try running 'manifest' action?\n";
    return;
  }
  warn "*** Did you forget to add $self->{metafile} to the MANIFEST?\n" unless exists $dist_files->{$self->{metafile}};
  
  my $dist_dir = $self->dist_dir;
  $self->delete_filetree($dist_dir);
  $self->add_to_cleanup($dist_dir);
  
  foreach my $file (keys %$dist_files) {
    $self->copy_if_modified(from => $file, to_dir => $dist_dir, verbose => 0);
  }
  
  $self->_sign_dir($dist_dir) if $self->{properties}{sign};
}

sub ACTION_disttest {
  my ($self) = @_;

  $self->depends_on('distdir');

  my $start_dir = $self->cwd;
  my $dist_dir = $self->dist_dir;
  chdir $dist_dir or die "Cannot chdir to $dist_dir: $!";
  # XXX could be different names for scripts
  
  local $ENV{'PERL5LIB'} = join $self->{config}{path_sep}, @INC;
  $self->run_perl_script('Build.PL') or die "Error executing 'Build.PL' in dist directory: $!";
  $self->run_perl_script('Build') or die "Error executing 'Build' in dist directory: $!";
  $self->run_perl_script('Build', [], ['test']) or die "Error executing 'Build test' in dist directory";
  chdir $start_dir;
}

sub ACTION_manifest {
  my ($self) = @_;
  
  require ExtUtils::Manifest;  # ExtUtils::Manifest is not warnings clean.
  local ($^W, $ExtUtils::Manifest::Quiet) = (0,1);
  ExtUtils::Manifest::mkmanifest();
}

sub dist_dir {
  my ($self) = @_;
  return "$self->{properties}{dist_name}-$self->{properties}{dist_version}";
}

sub ppm_name {
  my $self = shift;
  return 'PPM-' . $self->dist_dir;
}

sub script_files {
  my $self = shift;
  
  for ($self->{properties}{script_files}) {
    $_ = shift if @_;
    return unless $_;
    
    # Always coerce into a hash
    return $_ if UNIVERSAL::isa($_, 'HASH');
    return $_ = {$_ => 1} unless ref();
    return { map {$_,1} @$_ };
  }
}
BEGIN { *scripts = \&script_files; }

sub valid_licenses {
  return { map {$_, 1} qw(perl gpl artistic lgpl bsd open_source unrestricted restrictive unknown) };
}

sub _write_minimal_metadata {
  my $self = shift;
  my $p = $self->{properties};

  open META, "> $self->{metafile}"
    or die "Can't write $self->{metafile}: $!\n";

  print META <<"END_OF_META";
--- #YAML:1.0
name: $p->{dist_name}
version: $p->{dist_version}
author:
@{[ join "\n", map "  - $_", @{$self->dist_author} ]}
abstract: @{[ $self->dist_abstract ]}
license: $p->{license}
generated_by: Module::Build version @{[ Module::Build->VERSION ]}, without YAML.pm
END_OF_META

  close META;
}

sub ACTION_distmeta {
  my ($self) = @_;
  return if $self->{wrote_metadata};
  
  my $p = $self->{properties};
  $self->{metafile} = 'META.yml';
  
  unless ($p->{license}) {
    warn "No license specified, setting license = 'unknown'\n";
    $p->{license} = 'unknown';
  }
  unless ($self->valid_licenses->{ $p->{license} }) {
    die "Unknown license type '$p->{license}";
  }

  # If we're in the distdir, the metafile may exist and be non-writable.
  $self->delete_filetree($self->{metafile});

  unless (eval {require YAML; 1}) {
    warn <<EOM;
\nCouldn't load YAML.pm, generating a minimal META.yml without it.
Please check and edit the generated metadata, or consider installing YAML.pm.\n
EOM

    return $self->_write_minimal_metadata();
  }

  # We use YAML::Node to get the order nice in the YAML file.
  my $node = YAML::Node->new({});
  
  foreach (qw(dist_name dist_version dist_author dist_abstract license)) {
    (my $name = $_) =~ s/^dist_//;
    $node->{$name} = $self->$_();
  }

  foreach (qw(requires recommends build_requires conflicts dynamic_config)) {
    $node->{$_} = $p->{$_} if exists $p->{$_} and keys %{ $p->{$_} };
  }
  
  $node->{provides} = $self->find_dist_packages;

  $node->{generated_by} = "Module::Build version " . Module::Build->VERSION;
  
  # YAML API changed after version 0.30
  my $yaml_sub = $YAML::VERSION le '0.30' ? \&YAML::StoreFile : \&YAML::DumpFile;
  return $self->{wrote_metadata} = $yaml_sub->($self->{metafile}, $node );
}

sub _read_manifest {
  my ($self, $file) = @_;
  require ExtUtils::Manifest;  # ExtUtils::Manifest is not warnings clean.
  local ($^W, $ExtUtils::Manifest::Quiet) = (0,1);

  return scalar ExtUtils::Manifest::maniread($file);
}

sub find_dist_packages {
  my $self = shift;
  
  # Only packages in .pm files are candidates for inclusion here.
  # Only include things in the MANIFEST, not things in developer's
  # private stock.
  my $dist_files = $self->_read_manifest('MANIFEST');
  my @pm_files = grep {exists $dist_files->{$_}} keys %{ $self->find_pm_files };
  
  my %out;
  foreach my $file (@pm_files) {
    next if $file =~ m{^t/};  # Skip things in t/
    
    my $localfile = File::Spec->catfile( split m{/}, $file );
    my $version = $self->version_from_file( $localfile );
    
    foreach my $package ($self->_packages_inside($localfile)) {
      $out{$package}{file} = $file;
      $out{$package}{version} = $version if defined $version;
    }
  }
  return \%out;
}

sub _packages_inside {
  # XXX this SUCKS SUCKS SUCKS!  Damn you perl!
  my ($self, $file) = @_;
  my $fh = IO::File->new($file) or die "Can't read $file: $!";
  
  my (@packages, $p);
  push @packages, $p while (undef, $p) = 
    $self->_next_code_line($fh, qr/^[\s\{;]*package\s+([\w:]+)/);
  
  return @packages;
}

sub make_tarball {
  my ($self, $dir, $file) = @_;
  $file ||= $dir;
  
  print "Creating $file.tar.gz\n";
  
  if ($self->{args}{tar}) {
    my $tar_flags = $self->{properties}{verbose} ? 'cvf' : 'cf';
    $self->do_system($self->{args}{tar}, $tar_flags, "$file.tar", $dir);
    $self->do_system($self->{args}{gzip}, "$file.tar") if $self->{args}{gzip};
  } else {
    require Archive::Tar;
    # Archive::Tar versions >= 1.09 use the following to enable a compatibility
    # hack so that the resulting archive is compatible with older clients.
    $Archive::Tar::DO_NOT_USE_PREFIX = 0;
    my $files = $self->rscan_dir($dir);
    Archive::Tar->create_archive("$file.tar.gz", 1, @$files);
  }
}

sub install_base_relative {
  my ($self, $type) = @_;
  my %map = (
	     lib     => ['lib'],
	     arch    => ['lib', $self->{config}{archname}],
	     bin     => ['bin'],
	     script  => ['script'],
	     bindoc  => ['man', 'man1'],
	     libdoc  => ['man', 'man3'],
	    );
  return unless exists $map{$type};
  return File::Spec->catdir(@{$map{$type}});
}

sub install_destination {
  my ($self, $type) = @_;
  my $p = $self->{properties};
  
  if ($p->{install_base}) {
    return File::Spec->catdir($p->{install_base}, $self->install_base_relative($type));
  }
  return $p->{install_path}{$type} if exists $p->{install_path}{$type};
  return $p->{install_sets}{ $p->{installdirs} }{$type};
}

sub install_types {
  my $self = shift;
  return @{ $self->{properties}{install_types} }
}

sub install_map {
  my ($self, $blib) = @_;
  $blib ||= $self->blib;

  my %map;
  foreach my $type ($self->install_types) {
    my $localdir = File::Spec->catdir( $blib, $type );
    next unless -e $localdir;
    
    $map{$localdir} = $self->install_destination($type)
      or die "Can't figure out where to install things of type '$type'";
  }

  if (length(my $destdir = $self->{properties}{destdir} || '')) {
    foreach (keys %map) {
      # Need to remove volume from $map{$_} using splitpath, or else
      # we'll create something crazy like C:\Foo\Bar\E:\Baz\Quux
      my ($volume, $path) = File::Spec->splitpath( $map{$_}, 1 );
      $map{$_} = File::Spec->catdir($destdir, $path);
    }
  }
  
  $map{read} = '';  # To keep ExtUtils::Install quiet
  
  return \%map;
}

sub depends_on {
  my $self = shift;
  foreach my $action (@_) {
    $self->_call_action($action);
  }
}

sub rscan_dir {
  my ($self, $dir, $pattern) = @_;
  my @result;
  local $_; # find() can overwrite $_, so protect ourselves
  my $subr = !$pattern ? sub {push @result, $File::Find::name} :
             !ref($pattern) || (ref $pattern eq 'Regexp') ? sub {push @result, $File::Find::name if /$pattern/} :
	     ref($pattern) eq 'CODE' ? sub {push @result, $File::Find::name if $pattern->()} :
	     die "Unknown pattern type";
  
  File::Find::find({wanted => $subr, no_chdir => 1}, $dir);
  return \@result;
}

sub delete_filetree {
  my $self = shift;
  my $deleted = 0;
  foreach (@_) {
    next unless -e $_;
    print "Deleting $_\n";
    File::Path::rmtree($_, 0, 0);
    die "Couldn't remove '$_': $!\n" if -e $_;
    $deleted++;
  }
  return $deleted;
}

sub autosplit_file {
  my ($self, $file, $to) = @_;
  require AutoSplit;
  my $dir = File::Spec->catdir($to, 'lib', 'auto');
  AutoSplit::autosplit($file, $dir);
}

sub have_c_compiler {
  my ($self) = @_;
  my $p = $self->{properties}; 
  return $p->{have_compiler} if defined $p->{have_compiler};
  
  print "Checking if compiler tools configured... " if $p->{verbose};
  
  my $c_file = $self->config_file('compilet.c');
  {
    my $fh = IO::File->new("> $c_file") or die "Can't create $c_file: $!";
    print $fh "int boot_compilet() { return 1; }\n";
  }
  
  my ($obj_file, $lib_file);
  eval {
    local $p->{module_name} = 'compilet';  # Fool compile_c() and link_c() about the library name
    $obj_file = $self->compile_c($c_file);
    (my $file_base = $obj_file) =~ s/\.[^.]+$//;
    $file_base =~ tr/"//d;
    $lib_file = $self->link_c($self->config_dir, $file_base);
  };
  unlink for grep defined, $c_file, $obj_file, $lib_file;
  
  my $result = $p->{have_compiler} = $@ ? 0 : 1;
  print($result ? "ok.\n" : "failed.\n") if $p->{verbose};
  return $result;
}

sub compile_c {
  my ($self, $file) = @_;
  my ($cf, $p) = ($self->{config}, $self->{properties}); # For convenience
  
  # File name, minus the suffix
  (my $file_base = $file) =~ s/\.[^.]+$//;
  my $obj_file = "$file_base$cf->{obj_ext}";
  $self->add_to_cleanup($obj_file);
  return $obj_file if $self->up_to_date($file, $obj_file);
  
  my @include_dirs = map {"-I$_"} (@{$p->{include_dirs}},
				   File::Spec->catdir($cf->{installarchlib}, 'CORE'));
  
  my @extra_compiler_flags = $self->split_like_shell($p->{extra_compiler_flags});
  my @cccdlflags = $self->split_like_shell($cf->{cccdlflags});
  my @ccflags = $self->split_like_shell($cf->{ccflags});
  my @optimize = $self->split_like_shell($cf->{optimize});
  my @flags = (@include_dirs, @cccdlflags, @extra_compiler_flags, '-c', @ccflags, @optimize);
  
  my @cc = $self->split_like_shell($cf->{cc});
  
  $self->do_system(@cc, @flags, '-o', $obj_file, $file)
    or die "error building $cf->{dlext} file from '$file'";

  return $obj_file;
}

# Most platforms don't need prelinking stuff done
sub need_prelink_c { 0 }

sub prelink_c {
  my ($self, $to, $file_base) = @_;
  my ($p, $args) = ($self->{properties}, $self->{args});

  $file_base =~ tr/"//d; # remove any quotes
  my $basename = File::Basename::basename($file_base);

  print "ExtUtils::Mksymlists::Mksymlists('$file_base')\n";

  require ExtUtils::Mksymlists;
  ExtUtils::Mksymlists::Mksymlists( # dl. abbrev for dynamic library
    NAME     => $args->{dl_name}      || $p->{module_name},
    DLBASE   => $args->{dl_base}      || $basename,
    DL_VARS  => $args->{dl_vars}      || [],
    DL_FUNCS => $args->{dl_funcs}     || {},
    FUNCLIST => $args->{dl_func_list} || [],
    IMPORTS  => $args->{dl_imports}   || {},
    FILE     => $file_base,
  );

  # *One* of these will be created by Mksymlists depending on $^O
  local $_;
  $self->add_to_cleanup("$file_base.$_") for qw(ext def opt);
}

sub link_c {
  my ($self, $to, $file_base) = @_;
  my ($cf, $p) = ($self->{config}, $self->{properties}); # For convenience

  my $lib_file = File::Spec->catfile($to, File::Basename::basename("$file_base.$cf->{dlext}"));
  $self->add_to_cleanup($lib_file);
  my $objects = $p->{objects} || [];
  
  unless ($self->up_to_date(["$file_base$cf->{obj_ext}", @$objects], $lib_file)) {
    $self->prelink_c($to, $file_base) if $self->need_prelink_c;

    my @linker_flags = $self->split_like_shell($p->{extra_linker_flags});
    my @lddlflags = $self->split_like_shell($cf->{lddlflags});
    my @shrp = $self->split_like_shell($cf->{shrpenv});
    my @ld = $self->split_like_shell($cf->{ld});
    $self->do_system(@shrp, @ld, @lddlflags, '-o', $lib_file,
		     "$file_base$cf->{obj_ext}", @$objects, @linker_flags)
      or die "error building $file_base$cf->{obj_ext} from '$file_base.$cf->{dlext}'";
  }
  
  return $lib_file;
}

sub compile_xs {
  my ($self, $file) = @_;
  (my $file_base = $file) =~ s/\.[^.]+$//;

  print "$file -> $file_base.c\n";
  
  if (eval {require ExtUtils::ParseXS; 1}) {
    
    ExtUtils::ParseXS::process_file(
				    filename => $file,
				    prototypes => 0,
				    output => "$file_base.c",
				   );
  } else {
    # Ok, I give up.  Just use backticks.
    
    my $xsubpp  = $self->find_module_by_name('ExtUtils::xsubpp', \@INC)
      or die "Can't find ExtUtils::xsubpp in INC (@INC)";
    
    my $typemap =  $self->find_module_by_name('ExtUtils::typemap', \@INC);
    my $cf = $self->{config};
    my $perl = $self->{properties}{perl};
    
    my $command = (qq{$perl "-I$cf->{installarchlib}" "-I$cf->{installprivlib}" "$xsubpp" -noprototypes } .
		   qq{-typemap "$typemap" "$file"});
    
    print $command;
    my $fh = IO::File->new("> $file_base.c") or die "Couldn't write $file_base.c: $!";
    print $fh `$command`;
    close $fh;
  }
}

sub split_like_shell {
  my ($self, $string) = @_;
  
  return () unless defined($string) && length($string);
  return @$string if UNIVERSAL::isa($string, 'ARRAY');
  
  return $self->shell_split($string);
}

sub shell_split {
  return split ' ', $_[1];  # XXX This is naive - needs a fix
}

sub stdout_to_file {
  my ($self, $coderef, $redirect) = @_;
  local *SAVE;
  if ($redirect) {
    open SAVE, ">&STDOUT" or die "Can't save STDOUT handle: $!";
    open STDOUT, "> $redirect" or die "Can't create '$redirect': $!";
  }

  $coderef->();

  if ($redirect) {
    close STDOUT;
    open STDOUT, ">&SAVE" or die "Can't restore STDOUT: $!";
  }
}

sub run_perl_script {
  my ($self, $script, $preargs, $postargs) = @_;
  foreach ($preargs, $postargs) {
    $_ = [ $self->split_like_shell($_) ] unless ref();
  }
  my $perl = ref($self) ? $self->perl : $self->find_perl_interpreter;
  
  return $self->do_system($perl, @$preargs, $script, @$postargs);
}

# A lot of this looks Unixy, but actually it may work fine on Windows.
# I'll see what people tell me about their results.
sub process_xs {
  my ($self, $file) = @_;
  my $cf = $self->{config}; # For convenience

  # File name, minus the suffix
  (my $file_base = $file) =~ s/\.[^.]+$//;

  # .xs -> .c
  $self->add_to_cleanup("$file_base.c");
  unless ($self->up_to_date($file, "$file_base.c")) {
    $self->compile_xs($file);
  }
  
  # .c -> .o
  $self->compile_c("$file_base.c");

  # The .bs and .a files don't go in blib/lib/, they go in blib/arch/auto/.
  # Unfortunately we have to pre-compute the whole path.
  my $archdir;
  {
    my @dirs = File::Spec->splitdir($file_base);
    $archdir = File::Spec->catdir($self->blib,'arch','auto', @dirs[1..$#dirs]);
  }
  
  # .xs -> .bs
  $self->add_to_cleanup("$file_base.bs");
  unless ($self->up_to_date($file, "$file_base.bs")) {
    require ExtUtils::Mkbootstrap;
    print "ExtUtils::Mkbootstrap::Mkbootstrap('$file_base')\n";
    ExtUtils::Mkbootstrap::Mkbootstrap($file_base);  # Original had $BSLOADLIBS - what's that?
    {my $fh = IO::File->new(">> $file_base.bs")}  # touch
  }
  $self->copy_if_modified("$file_base.bs", $archdir, 1);
  
  # .o -> .(a|bundle)
  $self->link_c($archdir, $file_base);
}

sub do_system {
  my ($self, @cmd) = @_;
  print "@cmd\n";
  return !system(@cmd);
}

sub copy_if_modified {
  my $self = shift;
  my %args = (@_ > 3
	      ? ( verbose => 1, @_ )
	      : ( from => shift, to_dir => shift, flatten => shift )
	     );
  
  my $file = $args{from};
  unless (defined $file and length $file) {
    die "No 'from' parameter given to copy_if_modified";
  }
  
  my $to_path;
  if (defined $args{to} and length $args{to}) {
    $to_path = $args{to};
  } elsif (defined $args{to_dir} and length $args{to_dir}) {
    $to_path = File::Spec->catfile( $args{to_dir}, $args{flatten}
				    ? File::Basename::basename($file)
				    : $file );
  } else {
    die "No 'to' or 'to_dir' parameter given to copy_if_modified";
  }
  
  return if $self->up_to_date($file, $to_path); # Already fresh
  
  # Create parent directories
  File::Path::mkpath(File::Basename::dirname($to_path), 0, 0777);
  
  print "$file -> $to_path\n" if $args{verbose};
  File::Copy::copy($file, $to_path) or die "Can't copy('$file', '$to_path'): $!";
  return $to_path;
}

sub up_to_date {
  my ($self, $source, $derived) = @_;
  $source  = [$source]  unless ref $source;
  $derived = [$derived] unless ref $derived;

  return 0 if grep {not -e} @$derived;

  my $most_recent_source = time / (24*60*60);
  foreach my $file (@$source) {
    unless (-e $file) {
      warn "Can't find source file $file for up-to-date check";
      next;
    }
    $most_recent_source = -M _ if -M _ < $most_recent_source;
  }
  
  foreach my $derived (@$derived) {
    return 0 if -M $derived > $most_recent_source;
  }
  return 1;
}

1;
__END__


=head1 NAME

Module::Build::Base - Default methods for Module::Build

=head1 SYNOPSIS

  Please see the Module::Build documentation.

=head1 DESCRIPTION

The C<Module::Build::Base> module defines the core functionality of
C<Module::Build>.  Its methods may be overridden by any of the
platform-dependent modules in the C<Module::Build::Platform::>
namespace, but the intention here is to make this base module as
platform-neutral as possible.  Nicely enough, Perl has several core
tools available in the C<File::> namespace for doing this, so the task
isn't very difficult.

Please see the C<Module::Build> documentation for more details.

=head1 AUTHOR

Ken Williams, ken@mathforum.org

=head1 SEE ALSO

perl(1), Module::Build(3)

=cut
