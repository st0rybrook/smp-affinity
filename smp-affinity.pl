#!/usr/bin/perl
#
# USAGE
#
#   smp-affinity.pl --cpumap FILE
#
# Holger Eitzenberger <holger.eitzenberger@sophos.com>, 2013.

use strict;
use Getopt::Long;
use Data::Dumper;

our $VERSION = '0.1';

my $verbose;
my $cpumap_path;
my %options = (
	'c|cpumap=s' => \$cpumap_path,
	'h|help' => sub { usage(0) },
	'v|verbose+' => \$verbose,
	'version' => sub { print "smp-affinity.pl $VERSION\n";  exit 0 },
);

Getopt::Long::config('bundling');
Getopt::Long::GetOptions %options or die;

usage(1, 'cpumap missing, use --cpumap FILE') unless $cpumap_path;
cpumap_apply($cpumap_path);

exit 0;

sub itf_queue_get_irq
{
	my ($itfname, $queuenum) = @_;
	my $queue_irq = 0;

	open my $fh, '<', '/proc/interrupts' or die "interrupts: $!";

	while (my $line = <$fh>) {
		chomp $line;

		my @tokens = split /\s+/, $line;
		shift @tokens;

		my $irq = shift @tokens;
		# not an IRQ line
		next unless $irq =~ /^(\d+):/;
		my $irqnum = $1;

		my $if_queue = splice @tokens, -1;

		# FIXME support other formats
		if ($if_queue =~ /^$itfname$/) {
			# often this is only the Link Management IRQ, therefore
			# may be overwritten by next entry.
			$queue_irq = $irqnum;
		} elsif ($if_queue =~ /^$itfname-TxRx-$queuenum$/) {
			$queue_irq = $irqnum;
			last
		}
	}

	return $queue_irq;
}

sub itf_add_queue
{
	my ($itfs, $itfname, $queuenum, $cpunum) = @_;

	unless (exists $itfs->{$itfname}) {
		$itfs->{$itfname} = {
				NAME => $itfname, QUEUES => [],
			};
	}

	my $itf = $itfs->{$itfname};
	unless (defined ${$itf->{QUEUES}}[$queuenum]) {
		$itf->{QUEUES}[$queuenum] = {
				NUM => $queuenum, MASK => 0, IRQ => 0
			};
	}

	my $queue = ${$itf->{QUEUES}}[$queuenum];

	$queue->{IRQ} = itf_queue_get_irq($itfname, $queuenum) or die;
	$queue->{MASK} |= 1 << $cpunum;
}

sub itf_cmp
{
	$a =~ /^(\D+)(\d)$/;
	my ($aname, $anum) = ($1, $2);
	$b =~ /^(\D+)(\d)$/;
	my ($bname, $bnum) = ($1, $2);
	if ($verbose > 2) {
		print "itf_cmp: aname=$aname anum=$anum bname=$bname bnum=$bnum\n";
	}

	return $aname cmp $bname if $aname ne $bname;
	return $anum <=> $bnum;
}

sub dump_itfs
{
	my ($itfs) = @_;

	foreach my $itfname (sort itf_cmp keys %$itfs) {
		my $itf = $itfs->{$itfname} or die;

		print Dumper($itf);
	}
}

sub irq_set_affinity
{
	my ($irq, $mask) = @_;

	open my $fh, '>', "/proc/irq/$irq/smp_affinity" or do {
			die "irq$irq: smp_affinity: $!"
		};

	printf $fh "%x", $mask or die;
	printf "irq$irq: SMP affinity '%x'\n", $mask if $verbose > 1;
}

sub set_rps_affinity
{
	my ($itfname, $queuenum, $mask) = @_;

	my $path = "/sys/class/net/$itfname/queues/rx-$queuenum/rps_cpus";
	open my $fh, '>', "$path" or die "$itfname:$queuenum: $!";

	printf $fh "%x", $mask or die;
	printf "$itfname:$queuenum: RPS mask '%x'\n", $mask if $verbose > 1;
}

sub set_xps_affinity
{
	my ($itfname, $queuenum, $mask) = @_;

	my $path = "/sys/class/net/$itfname/queues/tx-$queuenum/xps_cpus";
	open my $fh, '>', "$path" or die "$itfname:$queuenum: $!";

	printf $fh "%x", $mask or die;
	printf "$itfname:$queuenum: XPS mask '%x'\n", $mask if $verbose > 1;
}

sub configure_itfs
{
	my ($itfs) = @_;

	foreach my $itfname (sort itf_cmp keys %$itfs) {
		my $itf = $itfs->{$itfname} or die;

		foreach my $queue (@{$itf->{QUEUES}}) {
			irq_set_affinity($queue->{IRQ}, $queue->{MASK});
			set_rps_affinity($itfname, $queue->{NUM}, $queue->{MASK});
			set_xps_affinity($itfname, $queue->{NUM}, $queue->{MASK});
			printf "$itf->{NAME}:$queue->{NUM}: affinity=%x rps=%x xps=%x\n",
				$queue->{MASK}, $queue->{MASK}, $queue->{MASK} if $verbose;
		}
	}
}

sub cpumap_apply
{
	my ($path) = @_;
	my %itfs;

	open my $fh, '<', $path or die "$path: $!";

	my $lineno;
	while (my $line = <$fh>) {
		chomp $line;
		$lineno++;

		my @tokens = split /\s+/, $line;
		my $cpu = shift @tokens;

		# EXAMPLE
		#
		#   cpu0: eth0:0 eth8:6 eth9:6
		if ($cpu !~ /^cpu(\d+):/) {
			usage(1, "$path:$lineno: $cpu: not a valid CPU");
		}
		my $cpunum = $1;

		foreach my $if_queue (@tokens) {
			if ($if_queue =~ /^(\S+):(\d+)$/) {
				my ($itf, $queuenum) = ($1, $2);

				itf_add_queue(\%itfs, $itf, $queuenum, $cpunum);
			}
		}
	}

	# TODO check if all queues of NIC are set

	#dump_itfs(\%itfs);

	configure_itfs(\%itfs);
}

sub usage
{
	my ($ret, $msg) = @_;

	print "smp-affinity.pl $msg\n" if $msg;

	print <<_EOT_;
smp-affinity.pl [OPTIONS]

OPTIONS

 -h
 --help         Show this help.

 -v
 --version      Show version.

_EOT_

	exit $ret
}
