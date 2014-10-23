#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "ppport.h"

#include <alpm.h>

/* #include "libalpm/alpm.h" */
/* #include "libalpm/alpm_list.h" */
/* #include "libalpm/deps.h" */
/* #include "libalpm/group.h" */
/* #include "libalpm/sync.h" */
/* #include "libalpm/trans.h" */

#include "const-c.inc"

/* These are missing in alpm.h */

/* from deps.h */
struct __pmdepend_t {
	pmdepmod_t mod;
	char *name;
	char *version;
};

struct __pmdepmissing_t {
	char *target;
	pmdepend_t *depend;
	char *causingpkg; /* this is used in case of remove dependency error only */
};
typedef struct __pmdepmissing_t pmdepmissing_t;

/* from group.h */
struct __pmgrp_t {
	/*group name*/
	char *name;
	/*list of pmpkg_t packages*/
	alpm_list_t *packages;
};

/* from sync.h */
struct __pmsyncpkg_t {
	pmpkgreason_t newreason;
	pmpkg_t *pkg;
	alpm_list_t *removes;
};

/* from conflicts.h */

struct __pmconflict_t {
    char *package1;
    char *package2;
};
typedef struct __pmconflict_t pmconflict_t;

struct __pmfileconflict_t {
    char *target;
    pmfileconflicttype_t type;
    char *file;
    char *ctarget;
};

typedef int           negative_is_error;
typedef pmdb_t      * ALPM_DB;
typedef pmpkg_t     * ALPM_Package;
typedef pmpkg_t     * ALPM_PackageFree;
typedef pmgrp_t     * ALPM_Group;

typedef pmdepend_t  * DependHash;
typedef pmconflict_t * ConflictArray;

typedef alpm_list_t * StringListFree;
typedef alpm_list_t * StringListNoFree;
typedef alpm_list_t * PackageListFree;
typedef alpm_list_t * PackageListNoFree;
typedef alpm_list_t * GroupList;
typedef alpm_list_t * DatabaseList;
typedef alpm_list_t * DependList;
typedef alpm_list_t * ListAutoFree;

/* CONVERTER FUNCTIONS ******************************************************/

/* These all convert C data structures to their Perl counterparts */

static SV * convert_stringlist ( alpm_list_t * string_list )
{
    AV *string_array = newAV();
    alpm_list_t *iter;
    for ( iter = string_list; iter; iter = iter->next ) {
        SV *string = newSVpv( iter->data, strlen( iter->data ) );
        av_push( string_array, string );
    }
    return newRV_noinc( (SV *)string_array );
}

static SV * convert_depend ( const pmdepend_t * depend )
{
    HV *depend_hash;
    SV *depend_ref;
    pmdepmod_t depmod;

    depend_hash = newHV();
    depend_ref  = newRV_inc( (SV *)depend_hash );
        
    hv_store( depend_hash, "name", 4, newSVpv( depend->name, 0 ), 0 );
    
    if ( depend->version != NULL ) {
        hv_store( depend_hash, "version", 7, newSVpv( depend->version, 0 ), 0 );
    }
    
    depmod = depend->mod;
    if ( depmod != 1 ) {
        hv_store( depend_hash, "mod", 3,
                  newSVpv( ( depmod == 2 ? "==" :
                             depmod == 3 ? ">=" :
                             depmod == 4 ? "<=" :
                             depmod == 5 ? ">"  :
                             depmod == 6 ? "<"  :
                             "ERROR" ), 0 ),
                  0 );
    }

    return depend_ref;
}

static SV * convert_depmissing ( const pmdepmissing_t * depmiss )
{
    HV *depmiss_hash;

    depmiss_hash = newHV();
    hv_store( depmiss_hash, "target", 6,
              newSVpv( depmiss->target, 0 ), 0 );
    hv_store( depmiss_hash, "cause", 5,
              newSVpv( depmiss->causingpkg, 0 ), 0 );
    hv_store( depmiss_hash, "depend", 6,
              convert_depend( depmiss->depend ), 0 );
    return newRV_inc( (SV *)depmiss_hash );
}

static SV * convert_conflict ( const pmconflict_t * conflict )
{
    AV *conflict_list;

    conflict_list = newAV();
    av_push( conflict_list, newSVpv( conflict->package1, 0 ) );
    av_push( conflict_list, newSVpv( conflict->package2, 0 ) );
    return newRV_inc( (SV *)conflict_list );
}

static SV * convert_fileconflict ( const pmfileconflict_t * fileconflict )
{
    HV *conflict_hash;

    conflict_hash = newHV();
    hv_store( conflict_hash, "type", 4,
              newSVpv( ( fileconflict->type == PM_FILECONFLICT_TARGET ?
                         "target" :
                         fileconflict->type == PM_FILECONFLICT_FILESYSTEM ?
                         "filesystem" : "ERROR" ), 0 ), 0);
    hv_store( conflict_hash, "target", 6, newSVpv( fileconflict->target, 0 ),
              0 );
    hv_store( conflict_hash, "file", 4, newSVpv( fileconflict->file, 0 ),
              0 );
    hv_store( conflict_hash, "ctarget", 7, newSVpv( fileconflict->ctarget, 0 ),
              0 );

    return newRV_inc( (SV *)conflict_hash );
}

void free_stringlist_errors ( char *string )
{
    free(string);
}

/* Copy/pasted from ALPM's conflict.c */
void free_fileconflict_errors ( pmfileconflict_t *conflict )
{
	if ( strlen( conflict->ctarget ) > 0 ) {
		free(conflict->ctarget);
	}
	free(conflict->file);
	free(conflict->target);
	free(conflict);
}

/* Copy/pasted from ALPM's deps.c */
void free_depmissing_errors ( pmdepmissing_t *miss )
{
	free(miss->depend->name);
	free(miss->depend->version);
	free(miss->depend);

	free(miss->target);
	free(miss->causingpkg);
	free(miss);
}

/* Copy/pasted from ALPM's conflict.c */
void free_conflict_errors ( pmconflict_t *conflict )
{
	free(conflict->package2);
	free(conflict->package1);
	free(conflict);
}

static SV * convert_trans_errors ( alpm_list_t * errors )
{
    HV *error_hash;
    /*HV *exception_stash;*/
    AV *error_list;
    alpm_list_t *iter;
    SV *ref;

    error_hash = newHV();
    error_list = newAV();

    hv_store( error_hash, "msg", 3,
              newSVpv( alpm_strerror( pm_errno ), 0 ), 0 );

    /* First convert the error list returned by the transaction
       into an array reference.  Also store the type. */

#define MAPERRLIST( TYPE )                                              \
    hv_store( error_hash, "type", 4, newSVpv( #TYPE, 0 ), 0 );          \
    for ( iter = errors ; iter ; iter = iter->next ) {                  \
        av_push( error_list,                                            \
                 convert_ ## TYPE ((pm ## TYPE ## _t *) iter->data ));  \
    }                                                                   \
    alpm_list_free_inner( errors,                                       \
                          (alpm_list_fn_free)                           \
                          free_ ## TYPE ## _errors );                   \
    alpm_list_free( errors );                                           \
    break

#define convert_invalid_delta(STR) newSVpv( STR, 0 )
#define pminvalid_delta_t char
#define free_invalid_delta_errors free
#define convert_invalid_package(STR) newSVpv( STR, 0 )
#define pminvalid_package_t char
#define free_invalid_package_errors free

    /* fprintf( stderr, "Entering switch statement\n" ); */

    switch ( pm_errno ) {
    case PM_ERR_FILE_CONFLICTS:    MAPERRLIST( fileconflict );
    case PM_ERR_UNSATISFIED_DEPS:  MAPERRLIST( depmissing );
    case PM_ERR_CONFLICTING_DEPS:  MAPERRLIST( conflict );
    case PM_ERR_DLT_INVALID:       MAPERRLIST( invalid_delta );
    case PM_ERR_PKG_INVALID:       MAPERRLIST( invalid_package );
    default:
        SvREFCNT_dec( (SV *)error_hash );
        SvREFCNT_dec( (SV *)error_list );
        return NULL;
    }

    /* fprintf( stderr, "Left switch statement\n" ); */

#undef MAPLIST
#undef convert_invalid_delta
#undef pminvalid_delta_t
#undef free_invalid_delta_errors
#undef convert_invalid_package
#undef pminvalid_package_t
#undef free_invalid_package_errors
    
    hv_store( error_hash, "list", 4, newRV_noinc( (SV *)error_list ),
              0 );
    /* error_hash_stash = gv_stashpv( "ALPM::Ex", 0 ); */

    ref = newRV_noinc( (SV *)error_hash );
    /* ref = sv_bless( ref, error_hash_stash ); */
    /* fprintf( stderr, "DEBUG: returning\n" ); */
    return ref;
}

/* CALLBACKS ******************************************************************/

/* Code references to use as callbacks. */
static SV *cb_log_sub      = NULL;
static SV *cb_download_sub = NULL;
static SV *cb_totaldl_sub  = NULL;
static SV *cb_fetch_sub    = NULL;
/* transactions */
static SV *cb_trans_event_sub    = NULL;
static SV *cb_trans_conv_sub     = NULL;
static SV *cb_trans_progress_sub = NULL;

/* String constants to use for log levels (instead of bitflags) */
static const char * log_lvl_error    = "error";
static const char * log_lvl_warning  = "warning";
static const char * log_lvl_debug    = "debug";
static const char * log_lvl_function = "function";
static const char * log_lvl_unknown  = "unknown";

void cb_log_wrapper ( pmloglevel_t level, char * format, va_list args )
{
    SV *s_level, *s_message;
    char *lvl_str, buffer[256];
    int lvl_len;
    dSP;

    if ( cb_log_sub == NULL ) return;

    /* convert log level bitflag to a string */
    switch ( level ) {
    case PM_LOG_ERROR:
        lvl_str = (char *)log_lvl_error;
        break;
    case PM_LOG_WARNING:
        lvl_str = (char *)log_lvl_warning;
        break;
    case PM_LOG_DEBUG:
        lvl_str = (char *)log_lvl_debug;
        break;
    case PM_LOG_FUNCTION:
        lvl_str = (char *)log_lvl_function;
        break;
    default:
        lvl_str = (char *)log_lvl_unknown; 
    }
    lvl_len = strlen( lvl_str );

    ENTER;
    SAVETMPS;

    s_level   = sv_2mortal( newSVpv( lvl_str, lvl_len ) );

    /*fprintf( stderr, "DEBUG: format = %s\n", format );*/

    s_message = sv_newmortal();
    vsnprintf( buffer, 255, format, args );
    sv_setpv( s_message, buffer );
    /* The following gets screwed up by j's: %jd or %ji, etc... */
    /*sv_vsetpvfn( s_message, format, strlen(format), &args,
                 (SV **)NULL, 0, NULL );*/
    
    PUSHMARK(SP);
    XPUSHs(s_level);
    XPUSHs(s_message);
    PUTBACK;

    call_sv(cb_log_sub, G_DISCARD);

    FREETMPS;
    LEAVE;
}

void cb_download_wrapper ( const char *filename, off_t xfered, off_t total )
{
    SV *s_filename, *s_xfered, *s_total;
    dSP;

    if ( cb_download_sub == NULL ) return;

    ENTER;
    SAVETMPS;

    s_filename  = sv_2mortal( newSVpv( filename, strlen(filename) ) );
    s_xfered    = sv_2mortal( newSViv( xfered ) );
    s_total     = sv_2mortal( newSViv( total ) );
    
    PUSHMARK(SP);
    XPUSHs(s_filename);
    XPUSHs(s_xfered);
    XPUSHs(s_total);
    PUTBACK;

    call_sv(cb_download_sub, G_DISCARD);

    FREETMPS;
    LEAVE;
}

void cb_totaldl_wrapper ( off_t total )
{
    SV *s_total;
    dSP;

    if ( cb_totaldl_sub == NULL ) return;

    ENTER;
    SAVETMPS;

    s_total = sv_2mortal( newSViv( total ) );
    
    PUSHMARK(SP);
    XPUSHs(s_total);
    PUTBACK;

    call_sv( cb_totaldl_sub, G_DISCARD );

    FREETMPS;
    LEAVE;
}

int cb_fetch_wrapper ( const char *url, const char *localpath,
                       time_t mtimeold, time_t *mtimenew )
{
    time_t new_time;
    int    count;
    SV     *result;
    int    retval;
    dSP;

    if ( cb_fetch_sub == NULL ) return -1;

    ENTER;
    SAVETMPS;

    PUSHMARK(SP);
    XPUSHs( sv_2mortal( newSVpv( url, strlen(url) )));
    XPUSHs( sv_2mortal( newSVpv( localpath, strlen(localpath) )));
    XPUSHs( sv_2mortal( newSViv( mtimeold )));
    PUTBACK;

    count = call_sv( cb_fetch_sub, G_EVAL | G_SCALAR );

    SPAGAIN;

    result = POPs;

    if ( ! SvTRUE( result ) || SvTRUE( ERRSV ) ) {
        if ( SvTRUE( ERRSV )) warn( SvPV_nolen( ERRSV ));

        retval = -1;
    }
    else {
        new_time = (time_t) SvIV( result );
        if ( mtimeold && new_time == mtimeold ) {
            retval = 1;
        }
        else {
            if ( mtimenew != NULL ) *mtimenew = new_time;
            retval = 0;
        }
    }

    PUTBACK;
    FREETMPS;
    LEAVE;

    return retval;
}

/* TRANSACTION CALLBACKS *****************************************************/

/* We convert all enum constants into strings.  An event is now a hash
   with a name, status (start/done/failed/""), and arguments.
   Arguments can have any name in the hash they prefer.  The event
   hash is passed as a ref to the callback. */
void cb_trans_event_wrapper ( pmtransevt_t event, void *arg_one, void *arg_two )
{
    SV *s_pkg, *s_event_ref;
    HV *h_event;
    AV *a_args;
    dSP;

    if ( cb_trans_event_sub == NULL ) return;

    ENTER;
    SAVETMPS;

    h_event = (HV*) sv_2mortal( (SV*) newHV() );

#define EVT_NAME(name) \
    hv_store( h_event, "name", 4, newSVpv( name, 0 ), 0 );

#define EVT_STATUS(name) \
    hv_store( h_event, "status", 6, newSVpv( name, 0 ), 0 );

#define EVT_PKG(key, pkgptr)                                    \
    s_pkg = newRV_noinc( newSV(0) );                            \
    sv_setref_pv( s_pkg, "ALPM::Package", (void *)pkgptr );     \
    hv_store( h_event, key, strlen(key), s_pkg, 0 );

#define EVT_TEXT(key, text)    \
    hv_store( h_event, key, 0, \
              newSVpv( (char *)text, 0 ), 0 );

    switch ( event ) {
    case PM_TRANS_EVT_CHECKDEPS_START:
        EVT_NAME("checkdeps")
        EVT_STATUS("start")
        break;
    case PM_TRANS_EVT_CHECKDEPS_DONE:
        EVT_NAME("checkdeps")
        EVT_STATUS("done")
        break;
    case PM_TRANS_EVT_FILECONFLICTS_START:
        EVT_NAME("fileconflicts")
        EVT_STATUS("start")
        break;
	case PM_TRANS_EVT_FILECONFLICTS_DONE:
        EVT_NAME("fileconflicts")
        EVT_STATUS("done")
        break;
	case PM_TRANS_EVT_RESOLVEDEPS_START:
        EVT_NAME("resolvedeps")
        EVT_STATUS("start")
        break;
	case PM_TRANS_EVT_RESOLVEDEPS_DONE:
        EVT_NAME("resolvedeps")
        EVT_STATUS("done")
        break;
	case PM_TRANS_EVT_INTERCONFLICTS_START:
        EVT_NAME("interconflicts")
        EVT_STATUS("start")
        break;
	case PM_TRANS_EVT_INTERCONFLICTS_DONE:
        EVT_NAME("interconflicts")
        EVT_STATUS("done")
        EVT_PKG("target", arg_one)
        break;
	case PM_TRANS_EVT_ADD_START:
        EVT_NAME("add")
        EVT_STATUS("start")
        EVT_PKG("package", arg_one)
        break;
	case PM_TRANS_EVT_ADD_DONE:
        EVT_NAME("add")
        EVT_STATUS("done")
        EVT_PKG("package", arg_one)
        break;
	case PM_TRANS_EVT_REMOVE_START:
        EVT_NAME("remove")
        EVT_STATUS("start")
        EVT_PKG("package", arg_one)
		break;
	case PM_TRANS_EVT_REMOVE_DONE:
        EVT_NAME("remove")
        EVT_STATUS("done")
        EVT_PKG("package", arg_one)
		break;
	case PM_TRANS_EVT_UPGRADE_START:
        EVT_NAME("upgrade")
        EVT_STATUS("start")
        EVT_PKG("package", arg_one)
		break;
	case PM_TRANS_EVT_UPGRADE_DONE:
        EVT_NAME("upgrade")
        EVT_STATUS("done")
        EVT_PKG("new", arg_one)
        EVT_PKG("old", arg_two)
		break;
	case PM_TRANS_EVT_INTEGRITY_START:
        EVT_NAME("integrity")
        EVT_STATUS("start")
		break;
	case PM_TRANS_EVT_INTEGRITY_DONE:
        EVT_NAME("integrity")
        EVT_STATUS("done")
		break;
	case PM_TRANS_EVT_DELTA_INTEGRITY_START:
        EVT_NAME("deltaintegrity")
        EVT_STATUS("start")
		break;
	case PM_TRANS_EVT_DELTA_INTEGRITY_DONE:
        EVT_NAME("deltaintegrity")
        EVT_STATUS("done")
		break;
	case PM_TRANS_EVT_DELTA_PATCHES_START:
        EVT_NAME("deltapatches")
        EVT_STATUS("start")
		break;
	case PM_TRANS_EVT_DELTA_PATCHES_DONE:
        EVT_NAME("deltapatches")
        EVT_STATUS("done")
        EVT_TEXT("pkgname", arg_one)
        EVT_TEXT("patch", arg_two)
		break;
	case PM_TRANS_EVT_DELTA_PATCH_START:
        EVT_NAME("deltapatch")
        EVT_STATUS("start")
		break;
	case PM_TRANS_EVT_DELTA_PATCH_DONE:
        EVT_NAME("deltapatch")
        EVT_STATUS("done")
		break;
	case PM_TRANS_EVT_DELTA_PATCH_FAILED:
        EVT_NAME("deltapatch")
        EVT_STATUS("failed")
        EVT_TEXT("error", arg_one)
		break;
	case PM_TRANS_EVT_SCRIPTLET_INFO:
        EVT_NAME("scriplet")
        EVT_STATUS("")
        EVT_TEXT("text", arg_one)
		break;
    case PM_TRANS_EVT_RETRIEVE_START:
        EVT_NAME("retrieve")
        EVT_STATUS("start")
        break;        
    }

#undef EVT_NAME
#undef EVT_STATUS
#undef EVT_PKG
#undef EVT_TEXT

    s_event_ref = newRV_noinc( (SV *)h_event );

    PUSHMARK(SP);
    XPUSHs(s_event_ref);
    PUTBACK;

    /* fprintf( stderr, "DEBUG: trans event callback start\n" ); */

    call_sv( cb_trans_event_sub, G_DISCARD );

    /* fprintf( stderr, "DEBUG: trans event callback stop\n" ); */

    FREETMPS;
    LEAVE;

    return;
}

void cb_trans_conv_wrapper ( pmtransconv_t type,
                             void *arg_one, void *arg_two, void *arg_three,
                             int *result )
{
    HV *h_event;
    SV *s_pkg;
    dSP;

    if ( cb_trans_conv_sub == NULL ) return;

    ENTER;
    SAVETMPS;

    h_event = (HV*) sv_2mortal( (SV*) newHV() );

#define EVT_PKG(key, pkgptr)                                    \
    do {                                                        \
        s_pkg = newRV_noinc( newSV(0) );                        \
        sv_setref_pv( s_pkg, "ALPM::Package", (void *)pkgptr ); \
        hv_store( h_event, key, strlen(key), s_pkg, 0 );        \
    } while (0)

#define EVT_TEXT(key, text)                                     \
    do {                                                        \
        hv_store( h_event, key, strlen(key),                    \
                  newSVpv( (char *)text, 0 ), 0 ); \
    } while (0)

#define EVT_NAME( NAME ) EVT_TEXT("name", NAME)

    hv_store( h_event, "id", 2, newSViv(type), 0 );
    
    switch ( type ) {
    case PM_TRANS_CONV_INSTALL_IGNOREPKG:
        EVT_NAME( "install_ignore" );
        EVT_PKG ( "package", arg_one );
        break;
    case PM_TRANS_CONV_REPLACE_PKG:
        EVT_NAME( "replace_package" );
        EVT_PKG ( "old", arg_one );
        EVT_PKG ( "new", arg_two );
        EVT_TEXT( "db",  arg_three  );
        break;
    case PM_TRANS_CONV_CONFLICT_PKG:
        EVT_NAME( "package_conflict" );
        EVT_TEXT( "package", arg_one );
        EVT_TEXT( "removable", arg_two );
        break;
    case PM_TRANS_CONV_CORRUPTED_PKG:
        EVT_NAME( "corrupted_file" );
        EVT_TEXT( "filename", arg_one );
        break;
    }

#undef EVENT
#undef EVT_NAME
#undef EVT_PKG
#undef EVT_TEXT

    PUSHMARK(SP);
    XPUSHs( newRV_noinc( (SV *)h_event ));
    PUTBACK;

    /* fprintf( stderr, "DEBUG: trans conv callback start\n" ); */

    call_sv( cb_trans_conv_sub, G_SCALAR );

    /* fprintf( stderr, "DEBUG: trans conv callback stop\n" ); */

    SPAGAIN;

    *result = POPi;

    PUTBACK;
    FREETMPS;
    LEAVE;

    return;
}

void cb_trans_progress_wrapper( pmtransprog_t type,
                                const char * desc,
                                int item_progress,
                                int total_count, int total_pos )
{
    HV *h_event;
    dSP;

    if ( cb_trans_progress_sub == NULL ) return;

    ENTER;
    SAVETMPS;

    h_event = (HV*) sv_2mortal( (SV*) newHV() );

#define EVT_TEXT(key, text)                        \
    do {                                           \
        hv_store( h_event, key, strlen(key),       \
                  newSVpv( (char *)text, 0 ), 0 ); \
    } while (0)

#define EVT_NAME( NAME ) EVT_TEXT("name", NAME); break;

#define EVT_INT(KEY, INT)                          \
    do {                                           \
        hv_store( h_event, KEY, strlen(KEY),       \
                  newSViv(INT), 0 );               \
    } while (0)

    switch( type ) {
    case PM_TRANS_PROGRESS_ADD_START:       EVT_NAME( "add"       );
    case PM_TRANS_PROGRESS_UPGRADE_START:   EVT_NAME( "upgrade"   );
    case PM_TRANS_PROGRESS_REMOVE_START:    EVT_NAME( "remove"    );
    case PM_TRANS_PROGRESS_CONFLICTS_START: EVT_NAME( "conflicts" );
    }

    EVT_INT ( "id",          type );
    EVT_TEXT( "desc",        desc );
    EVT_INT ( "item",        item_progress );
    EVT_INT ( "total_count", total_count );
    EVT_INT ( "total_pos",   total_pos );

#undef EVT_INT
#undef EVT_NAME

    PUSHMARK(SP);
    XPUSHs( newRV_noinc( (SV *)h_event ));
    PUTBACK;

    /* fprintf( stderr, "DEBUG: trans progress callback start\n" ); */

    call_sv( cb_trans_progress_sub, G_SCALAR );

    /* fprintf( stderr, "DEBUG: trans progress callback stop\n" ); */

    PUTBACK;
    FREETMPS;
    LEAVE;

    return;
}

/* This macro is used inside alpm_trans_init.
   CB_NAME is one of the transaction callback types (event, conv, progress).

   * [CB_NAME]_sub is the argument to the trans_init XSUB.
   * [CB_NAME]_func is a variable to hold the function pointer to pass
     to the real C ALPM function.
   * cb_trans_[CB_NAME]_wrapper is the name of the C wrapper function which
     calls the perl sub stored in the global variable:
   * cb_trans_[CB_NAME]_sub.
*/
#define UPDATE_TRANS_CALLBACK( CB_NAME )                                \
    if ( SvOK( CB_NAME ## _sub ) ) {                                    \
        if ( SvTYPE( SvRV( CB_NAME ## _sub ) ) != SVt_PVCV ) {          \
            croak( "Callback arguments must be code references" );      \
        }                                                               \
        if ( cb_trans_ ## CB_NAME ## _sub ) {                           \
            sv_setsv( cb_trans_ ## CB_NAME ## _sub, CB_NAME ## _sub );   \
        }                                                               \
        else {                                                          \
            cb_trans_ ## CB_NAME ## _sub = newSVsv( CB_NAME ## _sub );  \
        }                                                               \
        CB_NAME ## _func = cb_trans_ ## CB_NAME ## _wrapper;            \
    }                                                                   \
    else if ( cb_trans_ ## CB_NAME ## _sub != NULL ) {                  \
        /* If no event callback was provided for this new transaction,  \
           and an event callback is active, then remove the old callback. */ \
        SvREFCNT_dec( cb_trans_ ## CB_NAME ## _sub );                   \
        cb_trans_ ## CB_NAME ## _sub = NULL;                            \
    }

MODULE = ALPM    PACKAGE = ALPM

PROTOTYPES: DISABLE

INCLUDE: const-xs.inc

MODULE = ALPM    PACKAGE = ALPM::ListAutoFree

void
DESTROY(self)
    ListAutoFree self;
  CODE:
#   fprintf( stderr, "DEBUG Freeing memory for ListAutoFree\n" );
    alpm_list_free(self);

MODULE = ALPM    PACKAGE = ALPM::PackageFree

negative_is_error
DESTROY(self)
    ALPM_PackageFree self;
  CODE:
#   fprintf( stderr, "DEBUG Freeing memory for ALPM::PackageFree object\n" );
    RETVAL = alpm_pkg_free(self);
  OUTPUT:
    RETVAL

MODULE = ALPM    PACKAGE = ALPM

ALPM_PackageFree
alpm_pkg_load(filename, ...)
    const char *filename
  PREINIT:
    pmpkg_t *pkg;
#    unsigned short full;
  CODE:
#    full = ( items > 1 ? 1 : 0 );
    if ( alpm_pkg_load( filename, 1, &pkg ) != 0 )
        croak( "ALPM Error: %s", alpm_strerror( pm_errno ));
    RETVAL = pkg;
  OUTPUT:
    RETVAL

MODULE = ALPM    PACKAGE = ALPM    PREFIX=alpm_

negative_is_error
alpm_initialize()

negative_is_error
alpm_release()

MODULE = ALPM    PACKAGE = ALPM

SV *
alpm_option_get_logcb()
  CODE:
    RETVAL = ( cb_log_sub == NULL ? &PL_sv_undef : cb_log_sub );
  OUTPUT:
    RETVAL

void
alpm_option_set_logcb(callback)
    SV * callback
  CODE:
    if ( ! SvOK(callback) ) {
        if ( cb_log_sub != NULL ) {
            SvREFCNT_dec( cb_log_sub );
            alpm_option_set_logcb( NULL );
            cb_log_sub = NULL;
        }
    }
    else {
        if ( ! SvROK(callback) || SvTYPE( SvRV(callback) ) != SVt_PVCV ) {
            croak( "value for logcb option must be a code reference" );
        }

        if ( cb_log_sub ) {
            sv_setsv( cb_log_sub, callback );
        }
        else {
            cb_log_sub = newSVsv(callback);
            alpm_option_set_logcb( cb_log_wrapper );
        }
    }

SV *
alpm_option_get_dlcb()
  CODE:
    RETVAL = ( cb_download_sub == NULL ? &PL_sv_undef : cb_download_sub );
  OUTPUT:
    RETVAL

void
alpm_option_set_dlcb(callback)
    SV * callback
  CODE:
    if ( ! SvOK(callback) ) {
        if ( cb_download_sub != NULL ) {
            SvREFCNT_dec( cb_download_sub );
            alpm_option_set_dlcb( NULL );
            cb_download_sub = NULL;
        }
    }
    else {
        if ( ! SvROK(callback) || SvTYPE( SvRV(callback) ) != SVt_PVCV ) {
            croak( "value for dlcb option must be a code reference" );
        }

        if ( cb_download_sub ) {
            sv_setsv( cb_download_sub, callback );
        }
        else {
            cb_download_sub = newSVsv(callback);
            alpm_option_set_dlcb( cb_download_wrapper );
        }
    }


SV *
alpm_option_get_totaldlcb()
  CODE:
    RETVAL = ( cb_totaldl_sub == NULL ? &PL_sv_undef : cb_totaldl_sub );
  OUTPUT:
    RETVAL

void
alpm_option_set_totaldlcb(callback)
    SV * callback
  CODE:
    if ( ! SvOK(callback) ) {
        if ( cb_totaldl_sub != NULL ) {
            SvREFCNT_dec( cb_totaldl_sub );
            alpm_option_set_totaldlcb( NULL );
            cb_totaldl_sub = NULL;
        }
    }
    else {
        if ( ! SvROK(callback) || SvTYPE( SvRV(callback) ) != SVt_PVCV ) {
            croak( "value for totaldlcb option must be a code reference" );
        }

        if ( cb_totaldl_sub ) {
            sv_setsv( cb_totaldl_sub, callback );
        }
        else {
            cb_totaldl_sub = newSVsv(callback);
            alpm_option_set_totaldlcb( cb_totaldl_wrapper );
        }
    }

SV *
alpm_option_get_fetchcb()
  CODE:
    RETVAL = ( cb_fetch_sub == NULL ? &PL_sv_undef : cb_fetch_sub );
  OUTPUT:
    RETVAL

void
alpm_option_set_fetchcb(callback)
    SV * callback
  CODE:
    if ( ! SvOK(callback) ) {
        if ( cb_fetch_sub != NULL ) {
            SvREFCNT_dec( cb_fetch_sub );
            alpm_option_set_fetchcb( NULL );
            cb_fetch_sub = NULL;
        }
    }
    else {
        if ( ! SvROK(callback) || SvTYPE( SvRV(callback) ) != SVt_PVCV ) {
            croak( "value for fetchcb option must be a code reference" );
        }

        if ( cb_fetch_sub ) {
            sv_setsv( cb_fetch_sub, callback );
        }
        else {
            cb_fetch_sub = newSVsv(callback);
            alpm_option_set_fetchcb( cb_fetch_wrapper );
        }
    }


const char *
alpm_option_get_root()

negative_is_error
alpm_option_set_root(root)
    const char * root

const char *
alpm_option_get_dbpath()

negative_is_error
alpm_option_set_dbpath(dbpath)
    const char *dbpath

StringListNoFree
alpm_option_get_cachedirs()

negative_is_error
alpm_option_add_cachedir(cachedir)
    const char * cachedir

void
alpm_option_set_cachedirs(dirlist)
    StringListNoFree dirlist

negative_is_error
alpm_option_remove_cachedir(cachedir)
    const char * cachedir

const char *
alpm_option_get_logfile()

negative_is_error
alpm_option_set_logfile(logfile);
    const char * logfile

const char *
alpm_option_get_lockfile()

unsigned short
alpm_option_get_usesyslog()

void
alpm_option_set_usesyslog(usesyslog)
    unsigned short usesyslog

StringListNoFree
alpm_option_get_noupgrades()

void
alpm_option_add_noupgrade(pkg)
  const char * pkg

void
alpm_option_set_noupgrades(upgrade_list)
    StringListNoFree upgrade_list

negative_is_error
alpm_option_remove_noupgrade(pkg)
    const char * pkg

StringListNoFree
alpm_option_get_noextracts()

void
alpm_option_add_noextract(pkg)
    const char * pkg

void
alpm_option_set_noextracts(noextracts_list)
    StringListNoFree noextracts_list

negative_is_error
alpm_option_remove_noextract(pkg)
    const char * pkg

StringListNoFree
alpm_option_get_ignorepkgs()

void
alpm_option_add_ignorepkg(pkg)
    const char * pkg

void
alpm_option_set_ignorepkgs(ignorepkgs_list)
    StringListNoFree ignorepkgs_list

negative_is_error
alpm_option_remove_ignorepkg(pkg)
    const char * pkg

StringListNoFree
alpm_option_get_ignoregrps()

void
alpm_option_add_ignoregrp(grp)
    const char  * grp

void
alpm_option_set_ignoregrps(ignoregrps_list)
    StringListNoFree ignoregrps_list

negative_is_error
alpm_option_remove_ignoregrp(grp)
    const char  * grp

unsigned short
alpm_option_get_nopassiveftp()

void
alpm_option_set_nopassiveftp(nopasv)
    unsigned short nopasv

void
alpm_option_set_usedelta(usedelta)
    unsigned short usedelta

SV *
alpm_option_get_localdb()
  PREINIT:
    pmdb_t *db;
  CODE:
    db = alpm_option_get_localdb();
    if ( db == NULL )
        RETVAL = &PL_sv_undef;
    else {
        RETVAL = newSV(0);
        sv_setref_pv( RETVAL, "ALPM::DB", (void *)db );
    }
  OUTPUT:
    RETVAL

DatabaseList
alpm_option_get_syncdbs()

negative_is_error
alpm_db_unregister_all()

#--------------------------------------------------------------------------
# ALPM::DB Functions
#--------------------------------------------------------------------------

MODULE = ALPM    PACKAGE = ALPM    PREFIX=alpm_

ALPM_DB
alpm_db_register_local()

ALPM_DB
alpm_db_register_sync(sync_name)
    const char * sync_name

MODULE = ALPM   PACKAGE = ALPM::DB

const char *
name(db)
    ALPM_DB db
  CODE:
    RETVAL = alpm_db_get_name(db);
  OUTPUT:
    RETVAL

# We have a wrapper for this because it crashes on local db.
const char *
_url(db)
    ALPM_DB db
  CODE:
    RETVAL = alpm_db_get_url(db);
  OUTPUT:
    RETVAL

negative_is_error
set_server(db, url)
    ALPM_DB db
    const char * url
  CODE:
    RETVAL = alpm_db_setserver(db, url);
  OUTPUT:
    RETVAL

# Wrapper for this checks if a transaction is active.
negative_is_error
_update(db, level)
    ALPM_DB db
    int level
  CODE:
    RETVAL = alpm_db_update(level, db);
  OUTPUT:
    RETVAL

SV *
find(db, name)
    ALPM_DB db
    const char *name
  PREINIT:
    pmpkg_t *pkg;
  CODE:
    pkg = alpm_db_get_pkg(db, name);
    if ( pkg == NULL ) RETVAL = &PL_sv_undef;
    else {
        RETVAL = newSV(0);
        sv_setref_pv( RETVAL, "ALPM::Package", (void *)pkg );
    }
  OUTPUT:
    RETVAL

PackageListNoFree
_get_pkg_cache(db)
    ALPM_DB db
  CODE:
    RETVAL = alpm_db_get_pkgcache(db);
  OUTPUT:
    RETVAL

ALPM_Group
find_group(db, name)
    ALPM_DB db
    const char * name
  CODE:
    RETVAL = alpm_db_readgrp(db, name);
  OUTPUT:
    RETVAL
  
GroupList
_get_group_cache(db)
    ALPM_DB db
  CODE:
    RETVAL = alpm_db_get_grpcache(db);
  OUTPUT:
    RETVAL

# Wrapped to avoid arrayrefs (which are much easier in typemap)
PackageListFree
_search(db, needles)
    ALPM_DB db
    StringListFree needles
  CODE:
    RETVAL = alpm_db_search(db, needles);
  OUTPUT:
    RETVAL

MODULE=ALPM    PACKAGE=ALPM::Package    PREFIX=alpm_pkg_
    
negative_is_error
alpm_pkg_checkmd5sum(pkg)
    ALPM_Package pkg

# TODO: implement this in perl with LWP
#char *
#alpm_fetch_pkgurl(url)
#    const char *url

int
alpm_pkg_vercmp(a, b)
    const char *a
    const char *b

StringListFree
alpm_pkg_compute_requiredby(pkg)
    ALPM_Package pkg

const char *
alpm_pkg_filename(pkg)
    ALPM_Package pkg
  CODE:
    RETVAL = alpm_pkg_get_filename(pkg);
  OUTPUT:
    RETVAL

const char *
alpm_pkg_name(pkg)
    ALPM_Package pkg
  CODE:
    RETVAL = alpm_pkg_get_name(pkg);
  OUTPUT:
    RETVAL

const char *
alpm_pkg_version(pkg)
    ALPM_Package pkg
  CODE:
    RETVAL = alpm_pkg_get_version(pkg);
  OUTPUT:
    RETVAL

const char *
alpm_pkg_desc(pkg)
    ALPM_Package pkg
  CODE:
    RETVAL = alpm_pkg_get_desc(pkg);
  OUTPUT:
    RETVAL

const char *
alpm_pkg_url(pkg)
    ALPM_Package pkg
  CODE:
    RETVAL = alpm_pkg_get_url(pkg);
  OUTPUT:
    RETVAL

time_t
alpm_pkg_builddate(pkg)
    ALPM_Package pkg
  CODE:
    RETVAL = alpm_pkg_get_builddate(pkg);
  OUTPUT:
    RETVAL

time_t
alpm_pkg_installdate(pkg)
    ALPM_Package pkg
  CODE:
    RETVAL = alpm_pkg_get_installdate(pkg);
  OUTPUT:
    RETVAL

const char *
alpm_pkg_packager(pkg)
    ALPM_Package pkg
  CODE:
    RETVAL = alpm_pkg_get_packager(pkg);
  OUTPUT:
    RETVAL

const char *
alpm_pkg_md5sum(pkg)
    ALPM_Package pkg
  CODE:
    RETVAL = alpm_pkg_get_md5sum(pkg);
  OUTPUT:
    RETVAL

const char *
alpm_pkg_arch(pkg)
    ALPM_Package pkg
  CODE:
    RETVAL = alpm_pkg_get_arch(pkg);
  OUTPUT:
    RETVAL

off_t
alpm_pkg_size(pkg)
    ALPM_Package pkg
  CODE:
    RETVAL = alpm_pkg_get_size(pkg);
  OUTPUT:
    RETVAL

off_t
alpm_pkg_isize(pkg)
    ALPM_Package pkg
  CODE:
    RETVAL = alpm_pkg_get_isize(pkg);
  OUTPUT:
    RETVAL

pmpkgreason_t
alpm_pkg_reason(pkg)
    ALPM_Package pkg
  CODE:
    RETVAL = alpm_pkg_get_reason(pkg);
  OUTPUT:
    RETVAL

StringListNoFree
alpm_pkg_licenses(pkg)
    ALPM_Package pkg
  CODE:
    RETVAL = alpm_pkg_get_licenses(pkg);
  OUTPUT:
    RETVAL

StringListNoFree
alpm_pkg_groups(pkg)
    ALPM_Package pkg
  CODE:
    RETVAL = alpm_pkg_get_groups(pkg);
  OUTPUT:
    RETVAL

DependList
alpm_pkg_depends(pkg)
    ALPM_Package pkg
  CODE:
    RETVAL = alpm_pkg_get_depends(pkg);
  OUTPUT:
    RETVAL

StringListNoFree
alpm_pkg_optdepends(pkg)
    ALPM_Package pkg
  CODE:
    RETVAL = alpm_pkg_get_optdepends(pkg);
  OUTPUT:
    RETVAL

StringListNoFree
alpm_pkg_conflicts(pkg)
    ALPM_Package pkg
  CODE:
    RETVAL = alpm_pkg_get_conflicts(pkg);
  OUTPUT:
    RETVAL

StringListNoFree
alpm_pkg_provides(pkg)
    ALPM_Package pkg
  CODE:
    RETVAL = alpm_pkg_get_provides(pkg);
  OUTPUT:
    RETVAL

StringListNoFree
alpm_pkg_deltas(pkg)
    ALPM_Package pkg
  CODE:
    RETVAL = alpm_pkg_get_deltas(pkg);
  OUTPUT:
    RETVAL

StringListNoFree
alpm_pkg_replaces(pkg)
    ALPM_Package pkg
  CODE:
    RETVAL = alpm_pkg_get_replaces(pkg);
  OUTPUT:
    RETVAL

StringListNoFree
alpm_pkg_files(pkg)
    ALPM_Package pkg
  CODE:
    RETVAL = alpm_pkg_get_files(pkg);
  OUTPUT:
    RETVAL

StringListNoFree
alpm_pkg_backup(pkg)
    ALPM_Package pkg
  CODE:
    RETVAL = alpm_pkg_get_backup(pkg);
  OUTPUT:
    RETVAL

StringListNoFree
alpm_pkg_removes(pkg)
    ALPM_Package pkg
  CODE:
    RETVAL = alpm_pkg_get_removes(pkg);
  OUTPUT:
    RETVAL

ALPM_DB
alpm_pkg_db(pkg)
    ALPM_Package pkg
  CODE:
    RETVAL = alpm_pkg_get_db(pkg);
  OUTPUT:
    RETVAL

SV *
alpm_pkg_changelog(pkg)
    ALPM_Package pkg
  PREINIT:
    void *fp;
    char buffer[128];
    size_t bytes_read;
    SV *changelog_txt;
  CODE:
    changelog_txt = newSVpv( "", 0 );
    RETVAL = changelog_txt;

    fp = alpm_pkg_changelog_open( pkg );
    if ( fp ) {
        while ( 1 ) {
            bytes_read = alpm_pkg_changelog_read( (void *)buffer, 128,
                                                  pkg, fp );
            /* fprintf( stderr, "DEBUG: read %d bytes of changelog\n", */
            /*          bytes_read ); */
            if ( bytes_read == 0 ) break;
            sv_catpvn( changelog_txt, buffer, bytes_read );
        }
        alpm_pkg_changelog_close( pkg, fp );
    }
  OUTPUT:
    RETVAL

unsigned short
alpm_pkg_has_scriptlet(pkg)
    ALPM_Package pkg

unsigned short
alpm_pkg_has_force(pkg)
    ALPM_Package pkg

off_t
alpm_pkg_download_size(newpkg)
    ALPM_Package newpkg

#-----------------------------------------------------------------------------
# PACKAGE GROUPS
#-----------------------------------------------------------------------------

MODULE=ALPM    PACKAGE=ALPM::Group

const char *
name(grp)
    ALPM_Group grp
  CODE:
    RETVAL = alpm_grp_get_name(grp);
  OUTPUT:
    RETVAL

PackageListNoFree
_get_pkgs(grp)
    ALPM_Group grp
  CODE:
    RETVAL = alpm_grp_get_pkgs(grp);
  OUTPUT:
    RETVAL

#-----------------------------------------------------------------------------
# TRANSACTIONS
#-----------------------------------------------------------------------------

MODULE=ALPM    PACKAGE=ALPM

negative_is_error
alpm_trans_init(type, flags, event_sub, conv_sub, progress_sub)
    int type
    int flags
    SV  *event_sub
    SV  *conv_sub
    SV  *progress_sub
  PREINIT:
    alpm_trans_cb_event     event_func = NULL;
    alpm_trans_cb_conv      conv_func  = NULL;
    alpm_trans_cb_progress  progress_func  = NULL;
  CODE:
    /* I'm guessing that event callbacks provided for previous transactions
       shouldn't come into effect for later transactions unless explicitly
       provided. */

    UPDATE_TRANS_CALLBACK( event )
    UPDATE_TRANS_CALLBACK( conv )
    UPDATE_TRANS_CALLBACK( progress )

    RETVAL = alpm_trans_init( type, flags,
                              event_func, conv_func, progress_func );
  OUTPUT:
    RETVAL

negative_is_error
alpm_trans_sysupgrade(enable_downgrade)
    int enable_downgrade
  CODE:
    RETVAL = alpm_trans_sysupgrade( enable_downgrade );
  OUTPUT:
    RETVAL

MODULE=ALPM    PACKAGE=ALPM::Transaction

# This is used internally, we use the full name of the function
# (no PREFIX above)

negative_is_error
alpm_trans_addtarget(target)
    char * target

negative_is_error
DESTROY(self)
    SV * self
  CODE:
#   fprintf( stderr, "DEBUG Releasing the transaction\n" );
    RETVAL = alpm_trans_release();
  OUTPUT:
    RETVAL

MODULE=ALPM    PACKAGE=ALPM::Transaction    PREFIX=alpm_trans_

negative_is_error
alpm_trans_prepare(self)
    SV * self
  PREINIT:
    alpm_list_t *errors;
    HV *trans;
    SV *trans_error, **prepared;
  CODE:
    trans = (HV *) SvRV(self);

    prepared = hv_fetch( trans, "prepared", 8, 0 );
    if ( SvOK(*prepared) && SvTRUE(*prepared) ) {
        RETVAL = 0;
    }
    else {
        /* fprintf( stderr, "DEBUG: ALPM::Transaction::prepare\n" ); */

        errors = NULL;
        RETVAL = alpm_trans_prepare( &errors );

        if ( RETVAL == -1 ) {
            trans_error = convert_trans_errors( errors );
            if ( trans_error ) {
                hv_store( trans, "error", 5, trans_error, 0 );

                croak( "ALPM Transaction Error: %s", alpm_strerror( pm_errno ));
                fprintf( stderr, "ERROR: prepare shouldn't get here?\n" );
                RETVAL = 0;
            }

            /* If we don't catch all the kinds of errors we'll get memory
               leaks inside the list!  Yay! */
            if ( errors ) {
                fprintf( stderr,
                         "ERROR: unknown prepare error caused memory leak "
                         "at %s line %d\n", __FILE__, __LINE__ );
            }
        }
        else hv_store( trans, "prepared", 8, newSViv(1), 0 );

        /* fprintf( stderr, "DEBUG: ALPM::Transaction::prepare returning\n" ); */
    }
  OUTPUT:
    RETVAL

negative_is_error
alpm_trans_commit(self)
    SV * self
  PREINIT:
    alpm_list_t *errors;
    HV *trans;
    SV *trans_error, **prepared;
  CODE:
    /* make sure we are called as a method */
    if ( !( SvROK(self) /* && SvTYPE(self) == SVt_PVMG */
            && sv_isa( self, "ALPM::Transaction" ) ) ) {
        croak( "commit must be called as a method to ALPM::Transaction" );
    }

    trans = (HV *) SvRV(self);
    prepared = hv_fetch( trans, "prepared", 8, 0 );

    /*fprintf( stderr, "DEBUG: prepared = %d\n", SvIV(*prepared) );*/

    /* prepare before we commit */
    if ( ! SvOK(*prepared) || ! SvTRUE(*prepared) ) {
        PUSHMARK(SP);
        XPUSHs(self);
        PUTBACK;
        call_method( "prepare", G_DISCARD );
    }
    
    errors = NULL;
    RETVAL = alpm_trans_commit( &errors );

    if ( RETVAL == -1 ) {
        trans_error = convert_trans_errors( errors );
        if ( trans_error ) {
            hv_store( trans, "error", 5, trans_error, 0 );
            croak( "ALPM Transaction Error: %s", alpm_strerror( pm_errno ));
            fprintf( stderr, "ERROR: commit shouldn't get here?\n" );
            RETVAL = 0;
        }

        if ( errors ) {
            fprintf( stderr,
                     "ERROR: unknown commit error caused memory leak "
                     "at %s line %d\n",
                     __FILE__, __LINE__ );
        }
    }
  OUTPUT:
    RETVAL

negative_is_error
alpm_trans_interrupt(self)
    SV * self
  CODE:
    RETVAL = alpm_trans_interrupt();
  OUTPUT:
    RETVAL

negative_is_error
alpm_trans_sysupgrade(self, enable_downgrade)
    SV * self
    int enable_downgrade
  CODE:
    RETVAL = alpm_trans_sysupgrade( enable_downgrade );
  OUTPUT:
    RETVAL


# EOF
