package Module::Build::Compat;

use strict;
use vars qw($VERSION);
$VERSION = '0.03';

use File::Spec;
use IO::File;
use Config;
use Module::Build;
use Data::Dumper;

my %makefile_to_build = 
  (
   TEST_VERBOSE => 'verbose',
   VERBINST     => 'verbose',
   INC     => sub { map {('--extra_compiler_flags', "-I$_")} Module::Build->split_like_shell(shift) },
   POLLUTE => sub { ('--extra_compiler_flags', '-DPERL_POLLUTE') },
   INSTALLDIRS => sub {local $_ = shift; 'installdirs=' . (/^perl$/ ? 'core' : $_) },
   PREFIX => sub {die "Sorry, PREFIX is not supported.  See the Module::Build\n".
		      "documentation for 'destdir' or 'install_base' instead.\n"},
   LIB => sub { ('--install_path', 'lib='.shift()) },
  );



sub create_makefile_pl {
  my ($package, $type, $build, %args) = @_;
  
  die "Don't know how to build Makefile.PL of type '$type'"
    unless $type =~ /^(small|passthrough|traditional)$/;

  my $fh;
  if ($args{fh}) {
    $fh = $args{fh};
  } else {
    $args{file} ||= 'Makefile.PL';
    $fh = IO::File->new("> $args{file}") or die "Can't write $args{file}: $!";
  }

  print {$fh} "# Note: this file was auto-generated by ", __PACKAGE__, " version $VERSION\n";
  my $subclass_dir = File::Spec->catdir($build->config_dir, 'lib');
  $subclass_dir =~ s/([\'\\])/\\$1/g;
  
  if ($type eq 'small') {
    printf {$fh} <<'EOF', $subclass_dir, ref($build), ref($build);
    use Module::Build::Compat 0.02;
    use lib '%s';
    Module::Build::Compat->run_build_pl(args => \@ARGV);
    require %s;
    Module::Build::Compat->write_makefile(build_class => '%s');
EOF

  } elsif ($type eq 'passthrough') {
    printf {$fh} <<'EOF', $subclass_dir, ref($build), ref($build);
    
    unless (eval "use Module::Build::Compat 0.02; 1" ) {
      print "This module requires Module::Build to install itself.\n";
      
      require ExtUtils::MakeMaker;
      my $yn = ExtUtils::MakeMaker::prompt
	('  Install Module::Build now from CPAN?', 'y');
      
      unless ($yn =~ /^y/i) {
	die " *** Cannot install without Module::Build.  Exiting ...\n";
      }
      
      require Cwd;
      require File::Spec;
      require CPAN;
      
      # Save this 'cause CPAN will chdir all over the place.
      my $cwd = Cwd::cwd();
      my $makefile = File::Spec->rel2abs($0);
      
      CPAN::Shell->install('Module::Build::Compat')
	or die " *** Cannot install without Module::Build.  Exiting ...\n";
      
      chdir $cwd or die "Cannot chdir() back to $cwd: $!";
    }
    eval "use Module::Build::Compat 0.02; 1" or die $@;
    use lib '%s';
    Module::Build::Compat->run_build_pl(args => \@ARGV);
    require %s;
    Module::Build::Compat->write_makefile(build_class => '%s');
EOF
    
  } elsif ($type eq 'traditional') {

    my (%MM_Args, %prereq);
    if (eval "use Tie::IxHash; 1") {
      tie %MM_Args, 'Tie::IxHash'; # Don't care if it fails here
      tie %prereq,  'Tie::IxHash'; # Don't care if it fails here
    }
    
    my %name = ($build->module_name
		? (NAME => $build->module_name)
		: (DISTNAME => $build->dist_name));
    
    my %version = ($build->dist_version_from
		   ? (VERSION_FROM => $build->dist_version_from)
		   : (VERSION      => $build->dist_version)
		  );
    %MM_Args = (%name, %version);
    
    %prereq = ( %{$build->requires}, %{$build->build_requires} );
    %prereq = map {$_, $prereq{$_}} sort keys %prereq;
    
    delete $prereq{perl};
    $MM_Args{PREREQ_PM} = \%prereq;
    
    $MM_Args{INSTALLDIRS} = $build->installdirs eq 'core' ? 'perl' : $build->installdirs;
    
    $MM_Args{EXE_FILES} = [ sort keys %{$build->script_files} ] if $build->script_files;
    
    $MM_Args{PL_FILES} = {};
    
    local $Data::Dumper::Terse = 1;
    my $args = Data::Dumper::Dumper(\%MM_Args);
    $args =~ s/\{(.*)\}/($1)/s;
    
    print $fh <<"EOF";
use ExtUtils::MakeMaker;
WriteMakefile
$args;
EOF
  }
}


sub makefile_to_build_args {
  shift;
  my @out;
  foreach my $arg (@_) {
    my ($key, $val) = ($arg =~ /^(\w+)=(.+)/ ? ($1, $2) :
		       die "Malformed argument '$arg'");

    # Do tilde-expansion if it looks like a tilde prefixed path
    ( $val ) = glob( $val ) if $val =~ /^~/;

    if (exists $makefile_to_build{$key}) {
      my $trans = $makefile_to_build{$key};
      push @out, ref($trans) ? $trans->($val) : "$trans=$val";
    } elsif (exists $Config{lc($key)}) {
      push @out, 'config=' . lc($key) . "=$val";
    } else {
      # Assume M::B can handle it in lowercase form
      push @out, "\L$key\E=$val";
    }
  }
  return @out;
}

sub makefile_to_build_macros {
  my @out;
  while (my ($macro, $trans) = each %makefile_to_build) {
    # On some platforms (e.g. Cygwin with 'make'), the mere presence
    # of "EXPORT: FOO" in the Makefile will make $ENV{FOO} defined.
    # Therefore we check length() too.
    next unless exists $ENV{$macro} && length $ENV{$macro};
    my $val = $ENV{$macro};
    push @out, ref($trans) ? $trans->($val) : ($trans => $val);
  }
  return @out;
}

sub run_build_pl {
  my ($pack, %in) = @_;
  $in{script} ||= 'Build.PL';
  my @args = $in{args} ? $pack->makefile_to_build_args(@{$in{args}}) : ();
  print "# running $in{script} @args\n";
  Module::Build->run_perl_script($in{script}, [], \@args) or die "Couldn't run $in{script}: $!";
}

sub fake_makefile {
  my ($self, %args) = @_;
  unless (exists $args{build_class}) {
    warn "Unknown 'build_class', defaulting to 'Module::Build'\n";
    $args{build_class} = 'Module::Build';
  }

  my $perl = $args{build_class}->find_perl_interpreter;
  my $os_type = $args{build_class}->os_type;
  my $noop = ($os_type eq 'Windows' ? 'rem>nul' :
	      $os_type eq 'VMS'     ? 'Continue' :
	      'true');
  my $Build = 'Build --makefile_env_macros 1';

  # Start with a couple special actions
  my $maketext = <<"EOF";
all : force_do_it
	$perl $Build
realclean : force_do_it
	$perl $Build realclean
	$perl -e unlink -e shift $args{makefile}

force_do_it :
	@ $noop
EOF

  foreach my $action ($args{build_class}->known_actions) {
    next if $action =~ /^(all|realclean|force_do_it)$/;  # Don't double-define
    $maketext .= <<"EOF";
$action : force_do_it
	$perl $Build $action
EOF
  }
  
  $maketext .= "\n.EXPORT : " . join(' ', keys %makefile_to_build) . "\n\n";
  
  return $maketext;
}

sub fake_prereqs {
  my $file = File::Spec->catfile('_build', 'prereqs');
  my $fh = IO::File->new("< $file") or die "Can't read $file: $!";
  my $prereqs = eval do {local $/; <$fh>};
  close $fh;
  
  my @prereq;
  foreach my $section (qw/build_requires requires/) {
    foreach (keys %{$prereqs->{$section}}) {
      next if $_ eq 'perl';
      push @prereq, "$_=>q[$prereqs->{$section}{$_}]";
    }
  }

  return unless @prereq;
  return "#     PREREQ_PM => { " . join(", ", @prereq) . " }\n\n";
}


sub write_makefile {
  my ($pack, %in) = @_;
  $in{makefile} ||= 'Makefile';
  open  MAKE, "> $in{makefile}" or die "Cannot write $in{makefile}: $!";
  print MAKE $pack->fake_prereqs;
  print MAKE $pack->fake_makefile(%in);
  close MAKE;
}

1;
__END__


=head1 NAME

Module::Build::Compat - Compatibility with ExtUtils::MakeMaker

=head1 SYNOPSIS

 # In a Build.PL :
 use Module::Build;
 my $build = Module::Build->new
   ( module_name => 'Foo::Bar',
     license => 'perl',
     create_makefile_pl => 'passthrough' );
 ...

=head1 DESCRIPTION

Because ExtUtils::MakeMaker has been the standard way to distribute
modules for a long time, many tools (CPAN.pm, or your system
administrator) may expect to find a working Makefile.PL in every
distribution they download from CPAN.  If you want to throw them a
bone, you can use Module::Build::Compat to automatically generate a
Makefile.PL for you, in one of several different styles.

Module::Build::Compat also provides some code that helps out the
Makefile.PL at runtime.

=head1 METHODS

=over 4

=item create_makefile_pl( $style, $build )

Creates a Makefile.PL in the current directory in one of several
styles, based on the supplied Module::Build object C<$build>.  This is
typically controlled by passing the desired style as the
C<create_makefile_pl> parameter to Module::Build's C<new()> method;
the Makefile.PL will then be automatically created during the
C<distdir> action.

The currently supported styles are:

=over 4

=item small

A small Makefile.PL will be created that passes all functionality
through to the Build.PL script in the same directory.  The user must
already have Module::Build installed in order to use this, or else
they'll get a module-not-found error.

=item passthrough

This is just like the C<small> option above, but if Module::Build is
not already installed on the user's system, the script will offer to
use C<CPAN.pm> to download it and install it before continuing with
the build.

=item traditional

A Makefile.PL will be created in the "traditional" style, i.e. it will
use C<ExtUtils::MakeMaker> and won't rely on C<Module::Build> at all.
In order to create the Makefile.PL, we'll include the C<requires> and
C<build_requires> dependencies as the C<PREREQ_PM> parameter.

You don't want to use this style if during the C<perl Build.PL> stage
you ask the user questions, or do some auto-sensing about the user's
environment, or if you subclass Module::Build to do some
customization, because the vanilla Makefile.PL won't do any of that.

=back

=item run_build_pl( args => \@ARGV )

This method runs the Build.PL script, passing it any arguments the
user may have supplied to the C<perl Makefile.PL> command.  Because
ExtUtils::MakeMaker and Module::Build accept different arguments, this
method also performs some translation between the two.

C<run_build_pl()> accepts the following named parameters:

=over 4

=item args

The C<args> parameter specifies the parameters that would usually
appear on the command line of the C<perl Makefile.PL> command -
typically you'll just pass a reference to C<@ARGV>.

=item script

This is the filename of the script to run - it defaults to C<Build.PL>.

=back


=item write_makefile()

This method writes a 'dummy' Makefile that will pass all commands
through to the corresponding Module::Build actions.

C<write_makefile()> accepts the following named parameters:

=over 4

=item makefile

The name of the file to write - defaults to the string C<Makefile>.

=back

=back

=head1 SCENARIOS

So, some common scenarios are:

=over 4

=item 1.

Just include a Build.PL script (without a Makefile.PL
script), and give installation directions in a README or INSTALL
document explaining how to install the module.  In particular, explain
that the user must install Module::Build before installing your
module.  

Note that if you do this, you may make things easier for yourself, but
harder for people with older versions of CPAN or CPANPLUS on their
system, because those tools generally only understand the
F<Makefile.PL>/C<ExtUtils::MakeMaker> way of doing things.

=item 2.

Include a Build.PL script and a "traditional" Makefile.PL,
created either manually or with C<create_makefile_pl()>.  Users won't
ever have to install Module::Build if they use the Makefile.PL, but
they won't get to take advantage of Module::Build's extra features
either.

If you go this route, make sure you explicitly set C<PL_FILES> in the
call to C<WriteMakefile()> (probably to an empty hash reference), or
else MakeMaker will mistakenly run the Build.PL and you'll get an
error message about "Too early to run Build script" or something.  For
good measure, of course, test both the F<Makefile.PL> and the
F<Build.PL> before shipping.

=item 3.

Include a Build.PL script and a "pass-through" Makefile.PL
built using Module::Build::Compat.  This will mean that people can
continue to use the "old" installation commands, and they may never
notice that it's actually doing something else behind the scenes.  It
will also mean that your installation process is compatible with older
versions of tools like CPAN and CPANPLUS.

=back

=head1 AUTHOR

Ken Williams, ken@mathforum.org

=head1 SEE ALSO

Module::Build(3), ExtUtils::MakeMaker(3)

=cut
