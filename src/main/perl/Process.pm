#${PMpre} CAF::Process${PMpost}

use parent qw(CAF::Object);

use LC::Exception qw (SUCCESS);
use LC::Process;

use File::Which;
use File::Basename;

use overload ('""' => 'stringify_command');
use Readonly;

use English;

Readonly::Hash my %LC_PROCESS_DISPATCH => {
    output => \&LC::Process::output,
    toutput => \&LC::Process::toutput,
    run => \&LC::Process::run,
    trun => \&LC::Process::trun,
    execute => \&LC::Process::execute,
};

=pod

=head1 NAME

CAF::Process - Class for running commands in CAF applications

=head1 SYNOPSIS

    use CAF::Process;
    my $proc = CAF::Process->new ([qw (my command)], log => $self);
    $proc->pushargs (qw (more arguments));
    my $output = $proc->output();
    $proc->execute();

=head1 DESCRIPTION

This class provides a convenient wrapper to LC::Process
functions. Commands are logged at the verbose level.

All these methods return the return value of their LC::Process
equivalent. This is different from the command's exit status, which is
stored in $?.

Please use these functions, and B<do not> use C<``>, C<qx//> or
C<system>. These functions won't spawn a subshell, and thus are more
secure.

=cut

=head2 Private methods

=over

=item C<_initialize>

Initialize the process object. Arguments:

=over

=item C<$command>

A reference to an array with the command and its arguments.

=item C<%opts>

A hash with the command options:

=over

=item C<log>

The log object. If not supplied, no logging will be performed.

=item C<timeout>

Maximum execution time, in seconds, for the command. If it's too slow
it will be killed.

=item C<pid>

Reference to a scalar that will hold the child's PID.

=item C<stdin>

Data to be passed to the child's stdin

=item C<stdout>

Reference to a scalar that will have child's stdout

=item C<stderr>

Reference to a scalar that will hold the child's stderr.

=item C<keeps_state>

A boolean specifying whether the command respects the current system
state or not. A command that C<keeps_state> will be executed,
regardless of any value for C<NoAction>.

By default, commands modify the state and thus C<keeps_state> is
false.

=item C<sensitive>

A boolean specifying whether the arguments contain sensitive information
(like passwords). If C<sensitive> is true, the commandline will not be reported
(by default and when C<log> option is used, the commandline is reported
with verbose level).

This does not cover command output. If the output (stdout and/or stderr) contains
sensitve information, make sure to handle it yourself via C<stdout> and/or C<stderr>
options (or by using the C<output> method).

=item C<user>

Run command as effective user. The C<user> can be an id (all digits) or a name.

This only works when the current user is root.

In case a non-root user uses this option, or C<user> is not a valid user,
the initialisation will work but any actual execution will fail.

=item C<group>

Run command with effective group. The C<group> can be an id (all digits) or a name.

If C<user> is defined, and C<group> is not, the users primary group will be used
(instead of the default root group).

This only works when the current user is root.

In case a non-root user uses this option, or C<group> is not a valid group,
the initialisation will work but any actual execution will fail.

=back

These options will only be used by the execute method.

=back

=cut

sub _initialize
{
    my ($self, $command, %opts) = @_;

    $self->{log} = $opts{log} if defined($opts{log});

    if ($opts{keeps_state}) {
        $self->debug(1, "keeps_state set");
        $self->{NoAction} = 0
    };

    foreach my $name (qw(sensitive user group)) {
        $self->{$name} = $opts{$name};
    }

    $self->{COMMAND} = $command;

    $self->setopts (%opts);

    return SUCCESS;
}

=item _LC_Process

Run C<LC::Process> C<function> with arrayref arguments C<args>.

C<noaction_value> is is the value to return with C<NoAction>.

C<msg> and C<postmsg> are used to construct log message
C<<<msg> command: <COMMAND>[ <postmsg>]>>.

=cut

sub _get_uid_gid
{
    my ($self, $mode) = @_;

    my @res;
    my $what = $self->{$mode};
    if (defined($what)) {
        my $is_id = $what =~ m/^\d+$/ ? 1 : 0;
        my $is_user = $mode eq 'user' ? 1 : 0;
        # This is ugly
        #   But you cannot reference the builtin functions,
        #   maybe by using simple wrapper like my $fn = sub { builtin(@_) } (eg sub {getpwname($_[0])})
        #   But the getpw / getgr functions are safe to use (they do not die, just return undef)
        #   so no _safe_eval and a funcref required
        # For the is_id case, strictly not needed to check details, since setuid can change to non-known user
        #   But we don't allow that here.
        my @info = $is_id ?
            ($is_user ? getpwuid($what) : getgrgid($what)) :
            ($is_user ? getpwnam($what) : getgrnam($what));

        # What do we need from info: the IDs, and for users, also the primary groups
        if (@info) {
            # pwnam/pwuid: uid=2 and gid=3
            # grnam/uid: gid=2
            @res = ($info[2], $is_user ? $info[3] : undef);
        } else {
            $self->error("No such $mode $what (is user $is_user; is id $is_id)");
        }
    }

    return @res;
}

# set euid/egid if user and/or group was set
# returns 1 on success.
# on failure, report error and return undef
sub _set_eff_user_group
{
    my ($self, $orig) = @_;

    my ($uid, $gid, $pri_gid, $gid_full, $oper);

    my $restore = defined($orig) ? 1 : 0;

    if ($restore) {
        $oper = "restoring";
        ($uid, $gid) = @$orig;
        # We assume the original gid is the original list of groups
        $gid_full = "$gid";
    } else {
        $oper = "changing";

        # has to be array context
        ($uid, $pri_gid) = $self->_get_uid_gid('user');
        ($gid) = $self->_get_uid_gid('group');
        # use user primary group when no group specified
        $gid = $pri_gid if defined $uid && ! defined $gid;
        # This is how you set the GID to only the GID (i.e. no other groups)
        $gid_full = "$gid $gid" if defined $gid;
    }

    # return 1 or 0
    my $set_user = sub {
        return 1 if ! defined $uid;

        my $msg = "EUID from $EUID to $uid with UID $UID";
        if ($EUID == $uid) {
            $self->verbose(ucfirst($oper)." $msg: no changes required")
        } else {
            $EUID = $uid;
            if ($EUID == $uid) {
                $self->verbose(ucfirst($oper)." $msg")
            } else {
                $self->error("Something went wrong $oper $msg: $!");
                return 0;
            }
        }
        return 1;
    };

    # return 1 or 0
    my $set_group = sub {
        return 1 if ! defined($gid);

        my $msg = "EGID from $EGID to $gid with GID $GID";
        if ($EGID eq $gid_full) {
            $self->verbose(ucfirst($oper)." $msg: no changes required")
        } else {
            $EGID = $gid_full;
            if ($EGID eq $gid_full) {
                $self->verbose(ucfirst($oper)." $msg")
            } else {
                $self->error("Something went wrong $oper $msg: new EGID $EGID, reason $!");
                return 0;
            }
        }
        return 1;
    };

    my $res = 0;
    if ($restore) {
        # first restore user
        $res += &$set_user;
        $res += &$set_group if $res;
    } else {
        # first set group
        #   new euid might not have sufficient permissions to change the gid
        $res += &$set_group;
        $res += &$set_user if $res;
    }

    return $res == 2 ? 1 : 0;
}

sub _LC_Process
{
    my ($self, $function, $args, $noaction_value, $msg, $postmsg) = @_;

    my $res;
    $msg =~ s/^(\w)/Not \L$1/ if $self->noAction();
    $self->verbose("$msg command: ",
                   ($self->{sensitive} ? "$self->{COMMAND}->[0] <sensitive>" : $self->stringify_command()),
                   (defined($postmsg) ? " $postmsg" : ''));

    if ($self->noAction()) {
        $self->debug(1, "LC_Process in noaction mode for $function");
        $? = 0;
        $res = $noaction_value;
    } else {
        # The original GID (as list of groups)
        my $orig_user_group = [$UID, "$GID"];

        if ($self->_set_eff_user_group()) {
            my $funcref = $LC_PROCESS_DISPATCH{$function};
            if (defined($funcref)) {
                $res = $funcref->(@$args);
            } else {
                $self->error("Unsupported LC::Process function $function");
                $res = undef;
            }
        }

        # always try to restore
        $self->_set_eff_user_group($orig_user_group);
    }

    return $res;
}

=back

=head2 Public methods

=over

=item execute

Runs the command, with the options passed at initialization time. If
running on verbose mode, the exact command line and options are
logged.

Please, initialize the object with C<log => ''> if you are passing
confidential data as an argument to your command.

=back

=cut

sub execute
{
    my $self = shift;

    my @opts = ();
    foreach my $k (sort(keys (%{$self->{OPTIONS}}))) {
        push (@opts, "$k=$self->{OPTIONS}->{$k}");
    }

    return $self->_LC_Process(
        'execute',
        [$self->{COMMAND}, %{$self->{OPTIONS}}],
        0,
        "Executing",
        join (" ", "with options:", @opts),
        );
}

=over

=item output

Returns the output of the command. The output will not be logged for
security reasons.

=back

=cut

sub output
{
    my $self = shift;

    return $self->_LC_Process(
        'output',
        [@{$self->{COMMAND}}],
        '',
        "Getting output of",
        );
}

=over

=item toutput

Returns the output of the command, that will be run with the timeout
passed as an argument. The output will not be logged for security
reasons.

=back

=cut

sub toutput
{
    my ($self, $timeout) = @_;

    return $self->_LC_Process(
        'toutput',
        [$timeout, @{$self->{COMMAND}}],
        '',
        "Getting output of",
        "with $timeout seconds of timeout",
        );
}

=over

=item stream_output

Execute the commands using C<execute>, but the C<stderr> is
redirected to C<stdout>, and C<stdout> is processed with C<process>
function. The total output is aggregated and returned when finished.

Extra option is the process C<mode>. By default (or value C<undef>),
the new output is passed to C<process>. With mode C<line>, C<process>
is called for each line of output (i.e. separated by newline), and
the remainder of the output when the process is finished.

Another option are the process C<arguments>. This is a reference to the
array of arguments passed to the C<process> function.
The arguments are passed before the output to the C<process>: e.g.
if C<arguments =\> [qw(a b)]> is used, the C<process> function is
called like C<process(a,b,$newoutput)> (with C<$newoutput> the
new streamed output)

Example usage: during a C<yum install>, you want to stop the yum process
when an error message is detected.

    sub act {
        my ($self, $proc, $message) = @_;
        if ($message =~ m/error/) {
            $self->error("Error encountered, stopping process: $message");
            $proc->stop;
        }
    }

    $self->info("Going to start yum");
    my $p = CAF::Process->new([qw(yum install error)], input => 'init');
    $p->stream_output(\&act, mode => line, arguments => [$self, $p]);

=back

=cut

sub stream_output
{
    my ($self, $process, %opts) = @_;

    my ($mode, @process_args);
    $mode = $opts{mode} if exists($opts{mode});
    @process_args = @{$opts{arguments}} if exists($opts{arguments});

    my @total_out = ();
    my $last = 0;
    my $remainder = "";

    # Define this sub here. Makes no sense to define it outside this sub
    # Use anonymous sub to avoid "Variable will not stay shared" warnings
    my $stdout_func = sub  {
        my ($bufout) = @_;
        my $diff = substr($bufout, $last);
        if (defined($mode) && $mode eq 'line') {
            # split $diff in newlines
            # last part is empty? or has no newline, i.e. remainder
            my @lines = split(/\n/, $diff, -1); # keep trailing empty
            $remainder = pop @lines; # always possible
            # all others, print them
            foreach my $line (@lines) {
                $process->(@process_args, $line);
            }
        } else {
            # no remainder, leave it empty string
            $process->(@process_args, $diff);
        }
        $last = length($bufout) - length($remainder);
        push(@total_out,substr($diff, 0, length($diff) - length($remainder)));

        return 0;
    };

    $self->{OPTIONS}->{stderr} = 'stdout';
    $self->{OPTIONS}->{stdout} = $stdout_func;

    my $execute_res = $self->execute();

    # not called with empty remainder
    if ($remainder) {
        $process->(@process_args, $remainder);
        push(@total_out, $remainder);
    };

    return(join("", @total_out));
}

=over

=item run

Runs the command.

=back

=cut

sub run
{
    my $self = shift;

    return $self->_LC_Process(
        'run',
        [@{$self->{COMMAND}}],
        0,
        "Running the",
        );
}

=over

=item trun

Runs the command with $timeout seconds of timeout.

=back

=cut

sub trun
{
    my ($self, $timeout) = @_;

    return $self->_LC_Process(
        'trun',
        [$timeout, @{$self->{COMMAND}}],
        0,
        "Running the",
        "with $timeout seconds of timeout",
        );
}

=over

=item pushargs

Appends the arguments to the list of command arguments

=back

=cut

sub pushargs
{
    my ($self, @args) = @_;

    push (@{$self->{COMMAND}}, @args);
}

=over

=item setopts

Sets the hash of options passed to the options for the command

=back

=cut

sub setopts
{
    my ($self, %opts) = @_;

    foreach my $i (qw(timeout stdin stderr stdout shell)) {
        $self->{OPTIONS}->{$i} = $opts{$i} if exists($opts{$i});
    }

    # Initialize stdout and stderr if they exist. Otherwise, NoAction
    # runs will spill plenty of spurious uninitialized warnings.
    foreach my $i (qw(stdout stderr)) {
        if (exists($self->{OPTIONS}->{$i}) && ref($self->{OPTIONS}->{$i}) &&
            !defined(${$self->{OPTIONS}->{$i}})) {
            ${$self->{OPTIONS}->{$i}} = "";
        }
    }
}

=over

=item stringify_command

Return the command and its arguments as a space separated string.

=back

=cut

sub stringify_command
{
    my ($self) = @_;
    return join(" ", @{$self->{COMMAND}});
}

=over

=item get_command

Return the reference to the array with the command and its arguments.

=back

=cut

sub get_command
{
    my ($self) = @_;
    return $self->{COMMAND};
}


=over

=item get_executable

Return the executable (i.e. the first element of the command).

=back

=cut

sub get_executable
{
    my ($self) = @_;

    return ${$self->{COMMAND}}[0];

}


# Tests if a filename is executable. However, using -x
# makes this not mockable, and thus this test is separated
# from C<is_executable> in the C<_test_executable> private
# method for unittesting.
sub _test_executable
{
    my ($self, $executable) = @_;
    return -x $executable;
}

=over

=item is_executable

Checks if the first element of the
array with the command and its arguments, is executable.

It returns the result of the C<-x> test on the filename
(or C<undef> if filename can't be resolved).

If the filename is equal to the C<basename>, then the
filename to test is resolved using the
C<File::Which::which> method.
(Use C<./script> if you want to check a script in the
current working directory).

=back

=cut

sub is_executable
{
    my ($self) = @_;

    my $executable = $self->get_executable();

    if ($executable eq basename($executable)) {
        my $executable_path = which($executable);
        if (defined($executable_path)) {
            $self->debug (1, "Executable $executable resolved via which to $executable_path");
            $executable = $executable_path;
        } else {
            $self->debug (1, "Executable $executable couldn't be resolved via which");
            return;
        }
    }

    my $res = $self->_test_executable($executable);
    $self->debug (1, "Executable $executable is ", $res ? "": "not " , "executable");
    return $res;
}

=over

=item execute_if_exists

Execute after verifying the executable (i.e. the first
element of the command) exists and is executable.

If this is not the case the method returns 1.

=back

=cut


sub execute_if_exists
{
    my ($self) = @_;

    if ($self->is_executable()) {
        return $self->execute();
    } else {
        $self->verbose("Command ".$self->get_executable()." not found or not executable");
        return 1;
    }
}


1;

=pod

=head1 COMMON USE CASES

On the next examples, no log is used. If you want your component to
log the command, just add log => $self to the object creation.

=head2 Running a command

First, create the command:

    my $proc = CAF::Process->new (["ls", "-lh"]);

Then, choose amongst:

    $proc->run();
    $proc->execute();

=head2 Emulating backticks to get a command's output

Create the command:

    my $proc = CAF::Process->new (["ls", "-lh"]);

And get the output:

    my $output = $proc->output();

=head2 Piping into a command's stdin

Create the contents to be piped:

    my $contents = "Hello, world";

Create the command, specifying C<$contents> as the input, and
C<execute> it:

    my $proc = CAF::Process->new (["cat", "-"], stdin => $contents);
    $proc->execute();

=head2 Piping in and out

Suppose we want a bi-directional pipe: we provide the command's stdin,
and need to get its output and error:

    my ($stdin, $stdout, $stderr) = ("Hello, world", undef, undef);
    my $proc = CAF::Process->new (["cat", "-"], stdin => $stdin,
                                  stdout => \$stdout
                                  stderr => \$stderr);
    $proc->execute();

And we'll have the command's standard output and error on $stdout and
$stderr.

=head2 Creating the command dynamically

Suppose you want to add options to your command, dynamically:

    my $proc = CAF::Process->new (["ls", "-l"]);
    $proc->pushargs ("-a", "-h");
    if ($my_expression) {
        $proc->pushargs ("-S");
    }

    # Runs ls -l -a -h -S
    $proc->run();

=head2 Subshells

Okay, you B<really> want them. You can't live without them. You found
some obscure case that really needs a shell. Here is how to get
it. But please, don't use it without a B<good> reason:

    my $cmd = CAF::Process->new(["ls -lh|wc -l"], log => $self,
                                 shell => 1);
    $cmd->execute();

It will only work with the C<execute> method.

=head1 SEE ALSO

C<LC::Process>

=cut
