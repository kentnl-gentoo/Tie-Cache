#!/usr/local/bin/perl

use Cache;
use Benchmark;
use vars qw($Size);
use Data::Dumper;

$Size = 5000;
$| = 1;

sub report {
    my($desc, $count, $sub) = @_;
    print "[[ timing ]] $desc\n";
    print timestr(timeit($count, $sub))."\n";
    print "   ------   \n";
}

sub test {
    my($desc, $eval) = @_;
    my $result = eval { &$eval } ? "OK" : "ERROR - $@";
    print "$result ... $desc\n";
}

tie %cache, 'Tie::Cache', $Size, { MaxSize => 1000 };
my %normal;

print "++++ Benchmarking operations on Tie::Cache of size $Size\n\n";
my $i = 0;
report(
       "insert of $Size elements into normal %hash",
       $Size, 
       sub { $normal{++$i} = $i }
      );

$i = 0;
report(
       "insert of $Size elements into Tie::Cache %hash",
       $Size,
       sub { $cache{++$i} = $i }
       );

my $rv;
$i = 0;
report(
       "reading $Size elements from normal %hash",
       $Size,
       sub { $rv = $normal{++$i} }
       );
$i = 0;
report(
       "reading $Size elements from Tie::Cache %hash",
       $Size,
       sub { $rv = $cache{++$i} }
       );

$i = 0;
report(
       "deleting $Size elements from normal %hash",
       $Size,
       sub { $rv = delete $normal{++$i} }
       );

$i = 0;
report(
       "deleting $Size elements from Tie::Cache %hash",
       $Size,
       sub { $rv = delete $cache{++$i} }
       );

my $over = $Size * 2;
$i = 0;
report(
       "$over inserts overflowing Tie::Cache %hash ", 
       $over,
       sub { $cache{++$i} = $i; }
       );

print "\n++++ Testing for correctness\n\n";
my @keys = keys %cache;
test("number of keys in %cache = $Size",
     sub { @keys == $Size }
    );
test("first key in %cache = ".($Size + 1),
     sub { $keys[0] == $Size + 1 }
    );
test("last key in %cache = ".($Size + $Size),
     sub { $keys[$#keys] == $Size + $Size }
    );
test("first key value in %cache = ".($Size + 1),
     sub { $cache{$keys[0]} == $Size + 1 }
    );

delete $cache{$keys[0]};
test("deleting key $keys[0]; no value for deleted key",
     sub { ! $cache{$Size+1} }
    );
test("existance of deleted key = ! exists",
     sub { ! exists $cache{$Size+1} }
    );
@keys = keys %cache;
test("first key in %cache after delete = ".($Size + 2),
     sub { $keys[0] == $Size + 2 }
    );
test("keys in cache after delete = ".($Size-1),
     sub { keys %cache == $Size - 1 }
     );

print "\n++++ Stats for %cache\n\n";
my $obj = tied(%cache);
print join("\n", map { "$_:\t$obj->{$_}" } 'count', 'hit', 'miss', 'bytes');
print "\n";

exit;

# personalize the Tie::Cache object, by inheriting from it
package My::Cache;
@ISA = qw(Tie::Cache);

# override the read() and write() member functions
# these tell the cache what to do with a cache miss or flush
sub read { 
    my($self, $key) = @_; 
#    print "cache miss for $key, read() data\n";
    rand() * $key; 
}
sub write { 
    my($self, $key, $value) = @_;
#    print "flushing [$key, $value] from cache, write() data\n";
}

my $cache_size   = $ARGV[0] || 2;
my $num_to_cache = $ARGV[1] || 4;   
my $debug = $ARGV[2] || 2;

tie %cache, 'My::Cache', {
    MaxBytes => $cache_size * 20,
    MaxCount => $cache_size,
    Debug => $debug,
    WriteSync => 0,
    };   

# load the cache with new data, each through its contents,
# and then reload in reverse order.
my $count = 0;
for(1..$num_to_cache) { 
    print "READ data $_: $value\n";
    my $value = $cache{$_};
    if($count++ % 2) {
	print "INCREMENTING data for $_\n";
	$cache{$_} = $value + 1;
    }
}

for(1..$num_to_cache) {
    my $new_value = int(rand() * 10);
    print "WRITING data $new_value\n";
    $cache{$_} = $new_value;
}

while(my($k, $v) = each %cache) { print "EACH data $k: $v\n"; }
#while(my($k, $v) = each %cache) { print "EACH data $k: $v\n"; }
#for(my $i=$num_to_cache; $i>0; $i--) { print "read data $i: $cache{$i}\n"; }

# clear cache in 2 ways, write will flush out to disk
%cache = ();
undef %cache;
