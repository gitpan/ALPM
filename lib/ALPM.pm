package ALPM;

use 5.010000;
use strict;
use warnings;

require Exporter;
use AutoLoader;
use English qw(-no_match_vars);
use Scalar::Util qw(weaken);
use Carp;

use ALPM::Transaction;
use ALPM::Package;
use ALPM::PackageFree;
use ALPM::DB;

our $VERSION   = '0.03';
#our @EXPORT    = qw();
#our @EXPORT_OK = qw($ALPM);

# constants are only used internally... they are ugly.
sub AUTOLOAD {
    # This AUTOLOAD is used to 'autoload' constants from the constant()
    # XS function.

    my $constname;
    our $AUTOLOAD;
    ($constname = $AUTOLOAD) =~ s/.*:://;
    croak "&ALPM::constant not defined" if $constname eq 'constant';
    my ($error, $val) = constant($constname);
    if ($error) { croak $error; }
    {
	no strict 'refs';
	# Fixed between 5.005_53 and 5.005_61
#XXX	if ($] >= 5.00561) {
#XXX	    *$AUTOLOAD = sub () { $val };
#XXX	}
#XXX	else {
	    *$AUTOLOAD = sub { $val };
#XXX	}
    }
    goto &$AUTOLOAD;
}

require XSLoader;
XSLoader::load('ALPM', $VERSION);

####----------------------------------------------------------------------
#### GLOBAL VARIABLES
####----------------------------------------------------------------------

# Transaction global variable
our $_Transaction;

our %_IS_GETSETOPTION = ( map { ( $_ => 1 ) }
                          qw{ root dbpath cachedirs logfile usesyslog
                              noupgrades noextracts ignorepkgs holdpkgs ignoregrps
                              xfercommand nopassiveftp
                              logcb dlcb totaldlcb } );

our %_IS_GETOPTION    = ( %_IS_GETSETOPTION,
                         map { ( $_ => 1 ) } qw/ lockfile localdb syncdbs / );


### Transaction Constants ###
my %_TRANS_TYPES = ( 'upgrade'       => PM_TRANS_TYPE_UPGRADE(),
                     'remove'        => PM_TRANS_TYPE_REMOVE(),
                     'removeupgrade' => PM_TRANS_TYPE_REMOVEUPGRADE(),
                     'sync'          => PM_TRANS_TYPE_SYNC(),
                    );

my %_TRANS_FLAGS = ( 'nodeps'      => PM_TRANS_FLAG_NODEPS(),
                     'force'       => PM_TRANS_FLAG_FORCE(),
                     'nosave'      => PM_TRANS_FLAG_NOSAVE(),
                     'cascade'     => PM_TRANS_FLAG_CASCADE(),
                     'recurse'     => PM_TRANS_FLAG_RECURSE(),
                     'dbonly'      => PM_TRANS_FLAG_DBONLY(),
                     'alldeps'     => PM_TRANS_FLAG_ALLDEPS(),
                     'dlonly'      => PM_TRANS_FLAG_DOWNLOADONLY(),
                     'noscriptlet' => PM_TRANS_FLAG_NOSCRIPTLET(),
                     'noconflicts' => PM_TRANS_FLAG_NOCONFLICTS(),
                     'printuris'   => PM_TRANS_FLAG_PRINTURIS(),
                     'needed'      => PM_TRANS_FLAG_NEEDED(),
                     'allexplicit' => PM_TRANS_FLAG_ALLEXPLICIT(),
                     'unneeded'    => PM_TRANS_FLAG_UNNEEDED(),
                     'recurseall'  => PM_TRANS_FLAG_RECURSEALL()
                    );

####----------------------------------------------------------------------
#### CLASS INIT
####----------------------------------------------------------------------

initialize();

END { release() };

####----------------------------------------------------------------------
#### CLASS FUNCTIONS
####----------------------------------------------------------------------

sub import
{
    croak 'Invalid arguments to import function' if ( @_ == 0 );
    return if ( @_ == 1 );

    my ($class) = shift;

    if ( @_ == 1) {
        my $arg = shift;

        croak <<'END_ERROR' if ( ref $arg );
A single argument to ALPM's import must be a hash or a path to a
pacman.conf file
END_ERROR

        $class->load_config($arg);
        return;
    }

    croak q{Multiple options to ALPM's import must be a hash}
        unless ( @_ % 2 == 0 );

    $class->set_options( @_ );
    return;
}

####----------------------------------------------------------------------
#### CLASS METHODS
####----------------------------------------------------------------------

sub get_opt
{
    croak 'Invalid arguments to get_opt' if ( @_ != 2 );
    my ($class, $optname) = @_;

    croak qq{Unknown libalpm option "$optname"} unless ( $_IS_GETOPTION{$optname} );

    my $method_name = "get_$optname";
    my $func_ref = $ALPM::{$method_name};

    my $result = eval { $func_ref->() };
    if ($EVAL_ERROR) {
        # For ALPM errors, show the line number of the calling script, not
        # the line number of this module...
        croak $1 if ( $EVAL_ERROR =~ /^(ALPM .*) at .*? line \d+[.]$/ );
        croak $EVAL_ERROR;
    }

    return $result;
}

sub set_opt
{
    croak 'Not enough arguments to set_opt' if ( @_ < 3 );
    my ($class, $optname, $optval) = @_;

    $optname = lc $optname;
    unless ( $_IS_GETSETOPTION{$optname} ) {
        carp qq{Given option "$optname" is not settable or unknown};
        return;
    }

    my $method_name = "set_$optname";
    my $func_ref = $ALPM::{$method_name};
    my $func_arg;

    # If the option is a plural, it can accept multiple arguments
    # and must take an arrayref as argument...
    $func_arg = ( $optname =~ /s$/            ?
                  # is multivalue opt
                  ( ref $optval eq 'ARRAY'      ?
                    $optval                     :
                    ( [ $optval, @_[ 3 .. $#_ ] ] ) # auto-convert args to aref
                   )                          :
                  # is single valued opt
                  ( ref $optval eq '' || ref $optval eq 'CODE' ?
                    $optval                                    :
                    croak qq{Singular option "$optname" only takes a scalar value}
                   )
                 );

    return $func_ref->($func_arg);
}

sub get_options
{
    my $class = shift;

    if ( @_ == 0 ) {
        return %{$class->get_options_ref};
    }
    return @{$class->get_options_ref(@_)};
}

sub get_options_ref
{
    my $class = shift;

    # Return a list if option names are specified...
    return [ map { $class->get_opt($_) } @_ ]
        if ( @_ > 0 );

    # Return a hash of all options if no names are given...
    my $opts = {};
    for my $optname ( keys %_IS_GETOPTION ) {
        $opts->{$optname} = $class->get_opt($optname);
    }
    return $opts;
}

sub set_options
{
    croak 'Invalid arguments to set_options' if @_ < 2;
    my $class = shift;

    my %options;
    if ( @_ % 2 == 0 ) { %options = @_; }
    else {
        eval { %options = %{shift()} }
            or croak 'Argument to set_options must be either a hash or hashref';
    }

    for my $optname ( keys %options ) {
        $class->set_opt( $optname, $options{$optname} );
    }

    return 1;
}

sub register_db
{
    my $class = shift;

    if ( @_ == 0 || $_[0] eq 'local' ) {
        return $class->local_db;
    }

    my ($sync_name, $sync_url) = @_;

    croak 'You must supply a URL for the database'
        unless ( defined $sync_url );

    # Replace the literal string '$repo' with the repo's name,
    # like in the pacman config file... bad idea maybe?
    $sync_url =~ s/\$repo/$sync_name/g;

    # Set the server right away because function calls break in between...
    my $new_db = db_register_sync($sync_name);
    $new_db->_set_server($sync_url);
    return $new_db;
}

sub local_db
{
    my $class = shift;
    my $localdb = $class->get_opt('localdb');
    return $localdb if $localdb;
    return db_register_local();
}

sub get_repo_db
{
    croak 'Not enough arguments to get_repo_dbs' if ( @_ < 2 );
    my ($class, $repo_name) = @_;

    my ($found) = grep { $_->get_name eq $repo_name } @{ALPM->get_opt('syncdbs')};
    return $found;
}

sub load_config
{
    my ($class, $cfg_path) = @_;

    require ALPM::LoadConfig;
    my $loader = ALPM::LoadConfig->new;
    eval { $loader->load_file($cfg_path) };

    croak $EVAL_ERROR . "Config file parse error" if ($EVAL_ERROR);

    return 1;
}

sub transaction
{
    croak 'transaction must be called as a class method' unless ( @_ );
    my $class = shift;

    croak 'arguments to transaction method must be a hash'
        unless ( @_ % 2 == 0 );

    my %trans_opts = @_;
    my ($trans_type, $trans_flags) = (0) x 2;

    # A type must be specified...
    croak qq{unknown transaction type "$trans_type"}
        unless exists $_TRANS_TYPES{ $trans_opts{type} };
    $trans_type = $_TRANS_TYPES{ $trans_opts{type} };

    # Parse flags if they are provided...
    if ( exists $trans_opts{flags} ) {
        croak qq{transaction() option 'flags' must be an arrayref}
            unless ( ref $trans_opts{flags} ne 'ARRAY' );

        for my $flag ( @{ $trans_opts{flags} } ) {
            croak qq{unknown transaction flag "$flag"}
                unless exists $_TRANS_FLAGS{$flag};
            $trans_flags |= $_TRANS_FLAGS{$flag};
        }
    }

    eval { alpm_trans_init( $trans_type, $trans_flags,
                            $trans_opts{event} ) };
    if ( $@ ) {
        die "$@\n" unless ( $@ =~ /\AALPM Error:/ );
        $@ =~ s/ at .*? line \d+[.]\n//;
        croak $@;
    }

    # Return an object that will automatically release the transaction
    # when destroyed...
    my $t = ALPM::Transaction->new( %trans_opts );
    $_Transaction = $t;
    weaken $_Transaction; # keep track of active transactions
    return $t;
}

####----------------------------------------------------------------------
#### TIED HASH INTERFACE
####----------------------------------------------------------------------

my @_OPT_NAMES = sort keys %ALPM::_IS_GETOPTION;

sub TIEHASH
{
    my $class = shift;
    bless { 'KEY_ITER' => 0 }, $class;
}

sub DESTROY
{
    1;
}

sub EXISTS
{
    return exists $ALPM::_IS_GETOPTION{ $_[1] };
}

sub DELETE
{
    croak 'You cannot delete keys in this tied hash';
}

sub CLEAR
{
    croak 'You cannot empty this tied hash';
}

sub FETCH
{
    my ($self, $key) = @_;
    return $self->get_opt( $key );
}

sub STORE
{
    my ($self, $key, $value) = @_;
    return $self->set_opt( $key, $value );
}

sub FIRSTKEY
{
    my ($self) = @_;

    $self->{KEY_ITER} = 1;
    return $_OPT_NAMES[0];
}

sub NEXTKEY
{
    my ($self) = @_;

    return ( $self->{KEY_ITER} < scalar @_OPT_NAMES
             ? $_OPT_NAMES[ $self->{KEY_ITER}++ ]
             : undef );
}


1;

__END__

