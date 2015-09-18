use strict;
use warnings;

our $sleep = 0;
BEGIN {
    *CORE::GLOBAL::sleep = sub { $sleep += shift; };
}

use Test::More;
use Test::Quattor;
use CAF::Download qw(set_url_defaults);
use Test::Quattor::Object;
use Test::MockModule;
use Cwd;

my $obj = Test::Quattor::Object->new();
my $mock = Test::MockModule->new('CAF::Download');

=pod

=head1 SYNOPSIS

Test all methods for C<CAF::Download>

=over

=item _initialize

=cut


my $d = CAF::Download->new("/tmp/dest", ["http://localhost"], log => $obj);
isa_ok($d, 'CAF::Download', 'is a CAF::Download instance');
is($d->{setup}, 1, "default setup is 1");
is($d->{cleanup}, 1, "default cleanup is 1");

$d = CAF::Download->new("/tmp/dest", ["http://localhost"], setup => 0, cleanup => 0, log => $obj);
isa_ok($d, 'CAF::Download', 'is a CAF::Download instance');
is($d->{setup}, 0, "setup disabled / set to 0");
is($d->{cleanup}, 0, "cleanup disabled / set to 0");

=item prepare_destination

=cut

# TODO? what do we support?
# not much, just retrun the input
is_deeply($d->prepare_destination({x => 1}),
          {x => 1}, "prepare destination returns argument");

=item download

=cut

# test return undef with empty urls and destination
my $uniq_fail = 'yyz';
$d->{fail} = $uniq_fail;

$d->{destination} = undef;
$d->{urls} = [{}];
ok(defined($d->{urls}), 'urls attribute defined for this test');
ok(! defined($d->download()), 'download with undefined destination returns undef');
is($d->{fail}, $uniq_fail, 'download with undefined destination does not modify fail attribute');

$d->{destination} = '/a/file';
$d->{urls} = undef;
ok(defined($d->{destination}), 'destination attribute defined for this test');
ok(! defined($d->download()), 'download with undefined urls returns undef');
is($d->{fail}, $uniq_fail, 'download with undefined urls does not modify fail attribute');

# return undef with all failures
$d->{urls} = [];
ok(! defined($d->download()), 'download with empty urls returns undef (no more urls to try)');
is($d->{fail}, 'download failed: no more urls to try (total attempts 0).',
   'no more urls to try fail message');

# test loops and MAX_RETRIES
my $retrievals = [];
my $success = 3; # success after this number of retrievals
$mock->mock('retrieve', sub {
    my ($self, $url, $method, $auth) = @_;
    push(@$retrievals, [$url->{_id}, $method, $auth]);
    return scalar(@$retrievals) == $success;
});

# simple test
$d->{urls} = [
    {auth => ['a'], method => ['m'], retry_wait => 30, retries => 5, _string => 'u1', _id => 0},
];

$retrievals = [];
$sleep = 0;
ok($d->download(), 'download succesful');
is_deeply($retrievals, [
              [qw(0 m a)],
              [qw(0 m a)],
              [qw(0 m a)],
          ], "tried downloaded urls");
is($sleep, 2*30, 'slept 2*30 seconds due to retry_wait');

$d->{urls} = [
    {auth => ['a'], method => ['m'], retry_wait => 30, retries => 5, _string => 'u1', _id => 0},
    {auth => ['b', 'c'], method => ['n', 'p'], retry_wait => 20, retries => 25, _string => 'u2', _id => 1},
    {auth => ['d'], method => ['o'], _string => 'u3', _id => 2},
];

$success = -1; # fail all the way
$retrievals = [];
$sleep = 0;
ok(! defined($d->download()), 'download failed');
# sleep in total
my $max_retries = 1000;
# 1st url, 5 times minus 1 for very first attempt
# 2nd: 25*20, no sleep due to multiple auth/method
# 3rd: no sleep due to no retry_wait
is($sleep, (5-1)*30 + 25*20, "sleep due to retry_wait");
# total retrievals
# 1st 5 times
# 2nd: 25 times 2 method times 2 auth
# 3rd: no limit, so max_retries
is(scalar(@$retrievals), 5 + 25*2*2 + $max_retries, 'expected number of retrievals');
my @first_retrievals = @{$retrievals}[0..11];
is_deeply(\@first_retrievals, [
              [qw(0 m a)],
              [qw(1 n b)], [qw(1 n c)], [qw(1 p b)], [qw(1 p c)],
              [qw(2 o d)],
              [qw(0 m a)],
              [qw(1 n b)], [qw(1 n c)], [qw(1 p b)], [qw(1 p c)],
              [qw(2 o d)],
          ], "first 12 (i.e. 2 iterations) tried downloaded urls");

# original list of urls is not modified
is(scalar(@{$d->{urls}}), 3 , 'original list of urls unmodified');

=pod

=back

=cut

done_testing();
