#!/usr/local/bin/perl

use Cache;

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
