#${PMpre} CAF::Path${PMpost}

use parent qw(CAF::Exception);

use CAF::Object qw(SUCCESS CHANGED);
use LC::Check 1.22;
use LC::Exception qw (throw_error);

use Readonly;

use File::Path qw(rmtree);
use File::Temp qw(tempdir);
use File::Basename qw(dirname);

# do not use qw(move) or
# remove the qw() (move is in @EXPORT),
# as we define a move method below
use File::Copy qw();

use Scalar::Util qw(dualvar);

Readonly my $KEEPS_STATE => 'keeps_state';

Readonly::Hash my %CLEANUP_DISPATCH => {
    move => \&File::Copy::move,
    rmtree => \&rmtree,
    unlink => sub { return unlink(shift); },
};

# Use dispatch table instead of non-strict function by variable call
Readonly::Hash my %LC_CHECK_DISPATCH => {
    directory => \&LC::Check::directory,
    link => \&LC::Check::link,
    status => \&LC::Check::status,
};

Readonly::Array my @LC_CHECK_SILENT_FUNCTIONS => qw(directory status file link symlink hardlink absence);

our $EC = LC::Exception::Context->new->will_store_all;

=pod

=head1 NAME

CAF::Path - check that things are really the way we expect them to be

=head1 DESCRIPTION

Simplify common file and directory related operations e.g.

=over

=item directory creation

=item cleanup

=item (mockable) file/directory tests

=back

The class is based on B<LC::Check> with following major difference

=over

=item C<CAF::Object::NoAction> support builtin (and C<keeps_state> option to override it).

=item support C<CAF::Reporter> (incl. C<CAF::History>)

=item raised exceptions are catched, methods return SUCCESS on succes,
undef on failure and store the error message in the C<fail> attribute.

=item available as class-methods

=item return values

=over

=item undef: failure occured

=item SUCCESS: nothing changed (boolean true)

=item CHANGED: something changed (boolean true).

=back

=back

=head2 Functions

=over

=item mkcafpath

Returns an instance of C<CAF::Object> and C<CAF::Path>.
This instance is a simple way to use C<CAF::Path> when
subclassing is not possible. Allowed options are
C<<log => $logger>> and C<<NoAction => $noaction>>.

This function is not exported, to be used as e.g.
    use CAF::Path;
    ...
    my $cafpath = CAF::Path::mkcafpath(log => $logger);
    if(! defined($cafpath->directory($name)) {
        $logger->error("Failed to make directory $name: $cafpath->{fail}");
    };

=cut

sub mkcafpath
{
    # Internal class/package/namespace; limited to the scope of the block
    {
        package __caf_path_object;
        use parent qw(CAF::Object CAF::Path);
        sub _initialize ## no critic (Subroutines::ProhibitNestedSubs)
        {
            my ($self, %opts) = @_;
            foreach my $optname (qw(log NoAction)) {
                $self->{$optname} = $opts{$optname} if exists $opts{$optname};
            };
            return CAF::Object::SUCCESS;
        };
    }

    return __caf_path_object->new(@_);
}

=pod

=back

=head2 Methods

=over

=cut

# TODO: do we need some magic to be able to use as regular exported functions
# TODO: handle LC::Check _message, should use Reporter instead of print


=item LC_Check

Execute function C<<LC::Check::<function>>> with arrayref C<$args> and hashref C<$opts>.

C<CAF::Object::NoAction> is added to the options, unless C<keeps_state> is set.

The function is executed with C<_function_catch>.

=cut

sub LC_Check
{
    my ($self, $function, $args, $opts) = @_;

    my $noaction = $self->_get_noaction($opts->{$KEEPS_STATE}, $function);
    delete $opts->{$KEEPS_STATE};

    # Override noaction passed via opts
    $opts->{noaction} = $noaction;

    # make sure LC::Check::$function is silent unless in noaction mode
    # (or when explicitly set via silent option)
    if (! defined($opts->{silent}) &&
        grep {$_ eq $function} @LC_CHECK_SILENT_FUNCTIONS
        ) {
        $opts->{silent} = $noaction ? 0 : 1
    };


    my $funcref = $LC_CHECK_DISPATCH{$function};
    if (defined($funcref)) {
        return $self->_function_catch($funcref, $args, $opts, $EC);
    } else {
        return $self->fail("Unsupported LC::Check function $function");
    };
}

=item _untaint_path

Untaint the C<path> argument.

Returns undef on failure and sets the fail attribute with C<msg>

=cut

sub _untaint_path
{
    my ($self, $path, $msg) = @_;

    if ($path =~ m/^([^\0]+)$/) {
        return $1;
    } else {
        return $self->fail("Failed to untaint $msg: path $path");
    }
}


=item directory_exists

Test if C<directory> exists and is a directory.

This is basically the perl builtin C<-d>,
wrapped in a method to allow unittesting.

If  C<directory> is a symlink, the symlink target
is tested. If the symlink is broken (no target),
C<directory_exists> returns false.

=cut

sub directory_exists
{
    my ($self, $directory) = @_;
    return $directory && -d $directory;
}

=item file_exists

Test if C<filename> exists and is a file.

This is basically the perl builtin C<-f>,
wrapped in a method to allow unittesting.

If  C<filename> is a symlink, the symlink target
is tested. If the symlink is broken (no target),
C<file_exists> returns false.

=cut

sub file_exists
{
    my ($self, $filename) = @_;
    return $filename && -f $filename;
}

=item any_exists

Test if C<path> exists.

This is basically the perl builtin C<-e || -l>,
wrapped in a method to allow unittesting.

A broken symlink (symlink whose target doesn't
exist) exists: C<any_exists> returns true.

=cut

# LC::Check::_unlink uses lstat and -e _ (is that a single FS query?)

sub any_exists
{
    my ($self, $path) = @_;
    return $path && (-e $path || -l $path);
}

=item is_symlink

Test if C<path> is a symlink.

Returns true as long as C<path> is a symlink, including when the
symlink target doesn't exist.

=cut

sub is_symlink
{
    my ($self, $path) = @_;
    return $path && -l $path;
}

=item cleanup

cleanup removes C<dest> with backup support.

(Works like C<LC::Check::_unlink>, but has directory support
and no error throwing).

Returns CHANGED is something was cleaned-up, SUCCESS if nothing was done
and undef on failure (and sets the fail attribute).

The <backup> is a suffix for C<dest>.

If backup is undefined, use C<backup> attribute.
(Pass an empty string to disable backup with C<backup> attribute defined)
Any previous backup is C<cleanup>ed (without backup).
(Aside from the C<backup> attribute, this is the same as C<LC::Check::_unlink>
(and thus also C<CAF::File*>)).

Additional options

=over

=item keeps_state: boolean passed to C<_get_noaction>.

=back

=cut

# TODO: is the $self->{backup} a good idea?

sub cleanup
{
    my ($self, $dest, $backup, %opts) = @_;

    $dest = $self->_untaint_path($dest, "cleanup dest") || return;

    $self->_reset_exception_fail('cleanup', $EC);

    return SUCCESS if (! $self->any_exists($dest));

    $backup = $self->{backup} if (! defined($backup));

    # old is the backup location or undef if no backup is defined
    # (empty string as backup is not allowed, but 0 is)
    # 'if ($old)' can safely be used to test if a backup is needed
    my $old;
    if (defined($backup) and $backup ne '') {
        $backup = $self->_untaint_path($backup, "cleanup backup") || return;
        $old = $dest.$backup
    }

    # cleanup previous backup, no backup of previous backup!
    if ($old) {
        # Cleanup by move
        # No backup, this is passed to cleanup
        if (! $self->move($dest, $old, '', %opts)) {
            return $self->fail("cleanup: move to backup failed: $self->{fail}");
        };
    } else {
        my $method;
        my @args = ($dest);

        if($self->directory_exists($dest)) {
            $method = 'rmtree';
        } else {
            $method = 'unlink';
        }
        if($self->_get_noaction($opts{$KEEPS_STATE}, "cleanup: ")) {
            $self->verbose("cleanup: NoAction set, not going to $method with args ", join(',', @args));
        } else {
            my $res = $self->_safe_eval(
                $CLEANUP_DISPATCH{$method}, \@args, undef,
                "Cleanup $method failed to remove $dest",
                "Cleanup $method removed $dest",
                $EC
                );
            # move and unlink return 0 on failure, set $!
            # rmtree dies on failure
            if ($method eq 'rmtree') {
                return if defined($self->{fail});
            } else {
                return $self->fail("Cleanup $method failed to remove $dest: $!") if ! $res;
            };
        };
    };

    return CHANGED;
}


=item directory

Make sure a directory exists with proper options.

If the directory does not exists (or the C<temp> option is set),
it is created (including the parent directories as needed),
and uses C<LC::Check::directory> via C<LC_Check>.

Returns CHANGED if a change was made, SUCCESS if no changes were made
and undef in case of failure (and the C<fail> attribute is set).

The return value in absence of failure is a dualvar with integer value
SUCCESS/CHANGED, and the directory as string value
(in particular relevant for temporary directories).

Additional options

=over

=item owner/group/mode/mtime : options for C<CAF::Path::status>

=item temp

A boolean if true will create a a temporary directory using
B<File::Temp::tempdir>.

The directory name is the template to use (any trailing
C<X> characters will be replaced with random characters by C<tempdir>;
and the directory name will be padded up to at least 4 C<X>).

The C<CLEANUP> option is also set (an removal
attempt (incl. any files and/or subdirectries)
will be made at the end of the program).

=item keeps_state: boolean passed to C<_get_noaction>.

=back

=cut

# Differences with LC::Check::directory
#    only accepts one directory
#    returns directory name or undef (LC::Check::directory returns number of created directories)
#    tempdir support
#    set the status of existing directory
#    set the owner/group/mtime of new directory
#
# perl5.8.8 has no Temp::File->new() way of making a tempdir
# tempdir + CLEANUP is supported in 5.8.8x

sub directory
{
    my ($self, $directory, %opts) = @_;

    $directory = $self->_untaint_path($directory, "directory") || return;

    # assume we will create a new directory
    my $newdir = 1;

    $self->_reset_exception_fail('directory', $EC);

    if (delete $opts{temp}) {
        # pad to at least X by adding 4
        $directory .= 'X' x 4 if $directory !~ m/X{4}$/;

        if($self->_get_noaction($opts{$KEEPS_STATE}, "directory: (tempdir) ")) {
            $self->verbose("NoAction set, not going to create a temporary directory $directory with tempdir");
        } else {
            my $base = dirname($directory);
            if (! $self->directory_exists($base)) {
                if (! $self->directory($base, %opts)) {
                    return $self->fail("Failed to create basedir for temporary directory $directory: $self->{fail}");
                };
            }

            $directory = $self->_safe_eval(
                \&tempdir, [$directory], {CLEANUP => 1},
                "Failed to create temporary directory $directory",
                "Created temporary directory with tempdir",
                $EC
                );
            return if defined($self->{fail});
        }
        $self->debug(1, "Created temp directory $directory");
    } elsif ($self->directory_exists($directory)) {
        $newdir = 0;
        $self->debug(1, "Directory $directory already exists");
    } else {
        # Directory does not exist
        # LC_Check directory returns false only if there was a problem
        # Only mode option is used
        my $dopts = {%opts}; # a copy
        foreach my $invalid_opt (qw(owner group mtime)) {
            delete $dopts->{$invalid_opt};
        }
        return if ! $self->LC_Check('directory', [$directory], $dopts);
        $self->debug(1, "Created directory $directory");
    };

    # Always run status, but track newly created directories
    my $status = $self->status($directory, %opts);
    return if ! defined($status);

    # If we got here, no failures occured.
    # A new directory always implies something changed
    my $changed = ($newdir || $status == CHANGED) ? CHANGED : SUCCESS;
    return dualvar( $changed, $directory);
}


=item _make_link

This method is mainly a wrapper over C<LC::Check::link>
returning the standard C<CAF::Path> return values. Every option
supported by C<LC::Check::link> is supported. C<NoAction>
flag is handled by C<LC::Check::link> and C<keeps_state> option
is honored (overrides C<NoAction> if true). One important
difference is the order of the arguments: C<CAF::Path:_make_link>
and the methods based on it are following the Perl C<symlink>
(and C<ln> command) argument order.

This is an internal method, not supposed to be called directly.
Either call C<symlink> or C<hardlink> public methods instead.

=cut

sub _make_link
{
    my ($self, $target, $link_path, %opts) = @_;
    my $link_type = $opts{hard} ? "hardlink" : "symlink";

    $link_path = $self->_untaint_path($link_path, $link_type) || return;
    $target = $self->_untaint_path($target, $link_type) || return;

    $self->debug(2, "Creating $link_type $link_path to target $target");

    $self->_reset_exception_fail($link_type, $EC);

    my $status = $self->LC_Check('link', [$link_path, $target], \%opts);

    if ( defined($status) ) {
        return ($status ? CHANGED : SUCCESS);
    } else {
        return;
    }
}

=item hardlink

Create a hardlink C<link_path> whose target is C<target>.

On failure, returns undef and sets the fail attribute.
If C<link_path> exists and is a file, it is updated.
C<target> must exist (C<check> flag available in symlink()
is ignored for hardlinks) and it must reside in the same
filesystem as C<link_path>. If C<target_path> is a
relative path, it is interpreted from the current directory.
C<link_name> parent directory is created if it doesn't exist.

Returns SUCCESS on sucess if the hardlink already existed
with the same target, CHANGED if the hardlink was created
or updated, undef otherwise.

This method relies on C<_make_link> method to do the real work,
after enforcing the option saying that it is a hardlink.

=cut

sub hardlink
{
    my ($self, $target, $link_path, %opts) = @_;

    # Option passed to LC::Check::link to indicate a hardlink
    $opts{hard} = 1;

    return $self->_make_link($target, $link_path, %opts);
}


=item symlink

Create a symlink C<link_path> whose target is C<target>.

Returns undef and sets the fail attribute if C<link_path>
already exists and is not a symlink, except if this is a file
and option C<force> is defined and true. If C<link_path> exists
and is a symlink, it is updated. By default, the target is not
required to exist. If you want to ensure that it exists,
define option C<check> to true. Both C<link_path> and C<target>
can be relative paths: C<link_path> is interpreted as relatif
to the current directory and C<target> is kept relative.
C<link_path> parent directory is created if it doesn't exist.

Returns SUCCESS on sucess if the symlink already existed
with the same target, CHANGED if the symlink was created
or updated, undef otherwise.

This method relies on C<_make_link> method to do the real work,
after enforcing the option saying that it is a symlink.

=cut

sub symlink
{
    my ($self, $target, $link_path, %opts) = @_;

    # Option passed to LC::Check::link to indicate a symlink
    $opts{hard} = 0;

    # LC::Check::symlink() expects an option 'nocheck' but CAF::Path::symlink exposes
    # an option 'check', as the default in CAF::Path::symlink is not to check the
    # target existence. Convert it to 'nocheck'.
    if ( defined($opts{check}) ) {
        $opts{nocheck} = ! $opts{check};
        delete $opts{check};
    } else {
        $opts{nocheck} = 1;
    }

    return $self->_make_link($target, $link_path, %opts);
}


=item has_hardlinks

Method that returns the number of hardlinks for C<file>. The number of
hardlinks is the number of entries referring to the inodes minus 1. If
C<file> has no hardlink, the return value is 0. If C<file> is not a file,
the return value is C<undef>.

=cut

sub has_hardlinks
{
    my ($self, $file) = @_;
    $file = $self->_untaint_path($file, "has_hardlinks") || return;

    if ( ! $self->file_exists($file) && ! $self->is_symlink($file) ) {
        $self->debug(2, "has_hardlinks(): $file doesn't exist or is not a file");
        return;
    }

    my $nlinks = (lstat($file))[3];
    $self->debug(2, "Number of links to $file: $nlinks (hardlink if > 2)");
    return $nlinks ? $nlinks - 1 : 0;
}


=item is_hardlink

This method returns SUCCESS if C<path1> and C<path2> refer to the same file (inode).
It returns 0 if C<path1> and C<path2> both exist but are different files or are the same path
and C<undef> if one of the paths doesn't exist or is not a file.

Note: the result returned will be identical whatever is the order of C<path1> and C<path2>
arguments.

=cut

sub is_hardlink
{
    my ($self, $path1, $path2) = @_;
    $path1 = $self->_untaint_path($path1, "is_hardlink path1") || return;
    $path2 = $self->_untaint_path($path2, "is_hardlink path2") || return;

    if ( ! $self->file_exists($path1) && ! $self->is_symlink($path1) ) {
        $self->debug(2, "is_hardlink(): $path1 doesn't exist or is not a file");
        return;
    }
    if ( ! $self->file_exists($path2) && ! $self->is_symlink($path2) ) {
        $self->debug(2, "is_hardlink(): $path2 doesn't exist or is not a file");
        return;
    }

    my $link_inode = (lstat($path1))[1];
    my $target_inode = (lstat($path2))[1];

    $self->debug(2, "Comparing $path1 inode ($link_inode) and $path2 inode ($target_inode)");
    if ( ($link_inode == $target_inode) && ($path1 ne $path2)  ) {
        return SUCCESS;
    } else {
        return 0;
    }
}


=item status

Set the path stat options: C<owner>, C<group>, C<mode> and/or C<mtime>.

This is a wrapper around C<LC::Check::status>
and executed with C<LC_Check>.

Returns CHANGED if a change was made, SUCCESS if no changes were made
and undef in case of failure (and the C<fail> attribute is set).

Additional options

=over

=item keeps_state: boolean passed to C<_get_noaction>.

=back

=cut

# Satus on missing files returns undef (and file is not created).
# Status on a missing file returns CHANGED with NoAction.


sub status
{
    my ($self, $path, %opts) = @_;

    $path = $self->_untaint_path($path, "status") || return;

    my $status = $self->LC_Check("status", [$path], \%opts);
    if(defined($self->{fail})) {
        return;
    } else {
        return $status ? CHANGED : SUCCESS;
    }
}

=item move

Move/rename C<src> to C<dest>.

The final goal is to make sure C<src> does not exist anymore,
not that C<dest> exists after move (in particular, if C<src>
does not exist to start with, success is immediately returned,
and no backup of C<dest> is created).

The <backup> is a suffix for the cleanup of C<dest>
(and passed to C<cleanup> method).

(The basedir of C<dest> is created using C<directory> method.)

Additional options

=over

=item keeps_state: boolean passed to C<_get_noaction>.

=back

=cut

# TODO: support owner/group/... options
#    passed to directory when basedir of dest is missing
#    set them on dest file?

sub move
{
    my ($self, $src, $dest, $backup, %opts) = @_;

    $src = $self->_untaint_path($src, "move src") || return;
    $dest = $self->_untaint_path($dest, "move dest") || return;

    $self->_reset_exception_fail('move', $EC);

    return SUCCESS if (! $self->any_exists($src));

    # Make backup if needed using hardlink
    # File::Copy::move can handle existing destination
    if (defined($backup) and $backup ne '') {
        $backup = $self->_untaint_path($backup, "move backup") || return;
        my $old = $dest.$backup;
        if (! $self->hardlink($dest, $old, %opts)) {
            return $self->fail("move: backup of dest $dest to $old failed: $self->{fail}");
        };
    }

    if($self->_get_noaction($opts{$KEEPS_STATE}, "move: ")) {
        $self->verbose("move: NoAction set, not going to move $src to $dest");
    } else {
        my $base = dirname($dest);
        if (! $self->directory_exists($base)) {
            if (! $self->directory($base, %opts)) {
                return $self->fail("Failed to create basedir for dest $dest: $self->{fail}");
            };
        }

        # Move src to dest
        # File::Copy::move will try to use rename as much as possible,
        # (in which case operation is atomic).
        my $res = $self->_safe_eval(
            $CLEANUP_DISPATCH{move}, [$src, $dest], undef,
            "Failed to move $src to $dest",
            "Moved $src to $dest",
            $EC
            );
        # move returns 0 on failure, set $!
        return $self->fail("Failed to move $src to $dest: $!") if ! $res;
    };

    $self->debug(1, "Moved src $src to dest $dest");
    return CHANGED;
}

# private method doing the actual readdir
# this is the method to mock
# 2 args: directory name and test function
# they are not checked, and are supposed to be directory and CODE-ref
# (i.e. do not use this _listdir directly; use listdir instead)
# return arayref or undef on failure (fail attribute is set)
sub _listdir
{
    my ($self, $dir, $test) = @_;

    if (opendir(my $dh, $dir)) {
        local $@;
        my @res;
        eval {
            @res = grep { &$test($_, $dir) } readdir($dh);
        };
        closedir($dh);
        if ($@) {
            return $self->fail("_listdir: readdir grep $dir failed: $@");
        } else {
            return \@res;
        }
    } else {
        return $self->fail("_listdir: opendir $dir failed: $!");
    }
}

=item listdir

Return an arrayref of sorted directory entry names or undef on failure.
(The C<.> and C<..> are removed).

Can be used to replace C<glob()> as follows:

    ...
    foreach my $file (glob('/path/*.ext')) {
    ...

    replace by

    ...
    foreach my $file (@{$self->listdir('/path', filter => '\.ext$', adddir => 1)}) {
    ...


Options

=over

=item test

An (anonymous) sub used for testing.
The return value is interpreted as boolean value for filtering the
directory entry names (true value means the name is kept).

Accepts 2 arguments: first argument (C<< $_[0] >>) the directory entry name,
2nd argument (C<< $_[1] >>) the directory.

=item filter

A pattern or compiled pattern to filter directory entry names.
Matching names are kept.

=item inverse

Apply inverse test (or filter) logic.

=item adddir

Prefix the directory to the returned filenames (default false).

=item file_exists

Shortcut for test function that uses C<CAF::Path::file_exists> as test function.

=back

=cut


sub listdir
{
    my ($self, $dir, %opts) = @_;

    $dir = $self->_untaint_path($dir, "listdir directory") || return;
    $dir =~ s#/*$##;

    $self->_reset_exception_fail('listdir', $EC);

    if (! $self->directory_exists($dir)) {
        return $self->fail("listdir: directory $dir is not a directory");
    }

    my @tests = ();

    if (exists($opts{test})) {
        my $test = $opts{test};
        if (ref($test) eq 'CODE') {
            push(@tests, $test);
        } else {
            return $self->fail("listdir: test option must be a CODE reference");
        }
    }

    my $filter = $opts{filter};
    if (defined($filter)) {
        if (ref($filter) eq '') {
            # string is a pattern
            $filter = qr{$filter};
        }
        push(@tests, sub { return $_[0] =~ m/$filter/; });
    };

    if ($opts{file_exists}) {
        push(@tests, sub {return $self->file_exists("$_[1]/$_[0]")});
    }

    # apply any inverse logic
    # and force all functions to return 1 or 0
    my @newtests;
    foreach my $test (@tests) {
        push(@newtests, sub {
            # ^ bitwise xor; so force $inverse and test result to 0/1
            return ($opts{inverse} ? 1 : 0) ^ (&$test(@_) ? 1 : 0)
        });
    }

    # filter . and ..
    # add after inverse is applied!
    push(@newtests, sub {return ($_[0] ne '.' and $_[0] ne '..') ? 1 : 0});

    # run _listdir with first test function
    my $res_ref = $self->_listdir($dir, shift @newtests);
    # fail attribute set in _listdir
    return if ! defined($res_ref);

    my @res = sort @$res_ref;
    foreach my $test (@newtests) {
        # apply all remaining tests
        @res = grep { &$test($_, $dir) } @res;
    }

    if ($opts{adddir}) {
        @res = map {"$dir/$_"} @res;
    }

    return \@res;
}

=pod

=back

=cut


1;
