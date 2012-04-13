#!/usr/bin/env perl

=head1 NAME

biodb-to-json.pl - format JBrowse JSON as described in a configuration file

=head1 DESCRIPTION

Reads a configuration file, in a format currently documented in
docs/config.html, and formats JBrowse JSON from the data sources
defined in it.

=head1 USAGE

  bin/biodb-to-json.pl                               \
    --conf <conf file>                               \
    [--ref <ref seq names> | --refid <ref seq ids>]  \
    [--track <track name>]                           \
    [--out <output directory>]                       \
    [--compress]


  # format the example volvox track data
  bin/biodb-to-json.pl --conf docs/tutorial/conf_files/volvox.json

=head2 OPTIONS

=over 4

=item --help | -? | -h

Display an extended help screen.

=item --quiet | -q

Quiet.  Don't print progress messages.

=item --conf <conf file>

Required. Path to the configuration file to read.  File must be in JSON format.

=item --ref <ref seq name> | --refid <ref seq id>

Optional.  Single reference sequence name or id for which to process data.

By default, processes all data.

=item --out <output directory>

Directory where output should go.  Default: data/

=item --compress

If passed, compress the output with gzip (requires some web server configuration to serve properly).

=back

=cut

use strict;
use warnings;

use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use Bio::JBrowse::libs;

use Pod::Usage;

use Getopt::Long;
use Data::Dumper;
use Bio::JBrowse::GenomeDB;
use Bio::JBrowse::BioperlFlattener;
use Bio::JBrowse::ExternalSorter;

my ($confFile, $ref, $refid, $onlyLabel, $verbose, $nclChunk, $compress);
my $outdir = "data";
my $sortMem = 1024 * 1024 * 512;
my $help; my $quiet;
GetOptions("conf=s" => \$confFile,
	   "ref=s" => \$ref,
	   "refid=s" => \$refid,
	   "track=s" => \$onlyLabel,
	   "out=s" => \$outdir,
           "v+" => \$verbose,
           "nclChunk=i" => \$nclChunk,
           "compress" => \$compress,
           "sortMem=i" =>\$sortMem,
           "help|?|h" => \$help,
           "quiet|q" => \$quiet,
) or pod2usage();

pod2usage( -verbose => 2 ) if $help;
pod2usage( 'must provide a --conf argument' ) unless defined $confFile;

if (!defined($nclChunk)) {
    # default chunk size is 50KiB
    $nclChunk = 50000;
    # $nclChunk is the uncompressed size, so we can make it bigger if
    # we're compressing
    $nclChunk *= 4 if $compress;
}

my $gdb = Bio::JBrowse::GenomeDB->new( $outdir );

# determine which reference sequences we'll be operating on
my @refSeqs = @{ $gdb->refSeqs };
if (defined $refid) {
    @refSeqs = grep { $_->{id} eq $refid } @refSeqs;
    die "Didn't find a refseq with ID $refid (have you run prepare-refseqs.pl to supply information about your reference sequences?)" if $#refSeqs < 0;
} elsif (defined $ref) {
    @refSeqs = grep { $_->{name} eq $ref } @refSeqs;
    die "Didn't find a refseq with name $ref (have you run prepare-refseqs.pl to supply information about your reference sequences?)" if $#refSeqs < 0;
}
die "run prepare-refseqs.pl first to supply information about your reference sequences" if $#refSeqs < 0;


# read our conf file
die "conf file '$confFile' not found or not readable" unless -r $confFile;
my $config = Bio::JBrowse::JsonGenerator::readJSON($confFile);

# open and configure the db defined in the config file
eval "require $config->{db_adaptor}; 1" or die $@;
my $db = eval {$config->{db_adaptor}->new(%{$config->{db_args}})} or warn $@;
die "Could not open database: $@" unless $db;
if (my $refclass = $config->{'reference class'}) {
    eval {$db->default_class($refclass)};
}
$db->strict_bounds_checking(1) if $db->can('strict_bounds_checking');
$db->absolute(1)               if $db->can('absolute');


foreach my $seg (@refSeqs) {
    my $segName = $seg->{name};
    print "\nworking on refseq $segName\n" unless $quiet;

    # get the list of tracks we'll be operating on
    my @tracks = defined $onlyLabel
                   ? grep { $_->{"track"} eq $onlyLabel } @{$config->{tracks}}
                   : @{$config->{tracks}};

    foreach my $trackCfg ( @tracks ) {
        my $trackLabel = $trackCfg->{'track'};
        print "working on track $trackLabel\n" unless $quiet;

        my $mergedTrackCfg = assemble_track_config(
                                 $config,
                                 { key      => $trackLabel,
                                   %$trackCfg,
                                   compress => $compress,
                                 },
                             );

        print "mergedTrackCfg: " . Dumper( $mergedTrackCfg ) if $verbose && !$quiet;

        my $track = $gdb->getTrack( $trackLabel, $mergedTrackCfg, $mergedTrackCfg->{key} )
                 || $gdb->createFeatureTrack( $trackLabel,
                                              $mergedTrackCfg,
                                              $mergedTrackCfg->{key},
                                             );

        my @feature_types = @{$trackCfg->{"feature"}};
        next unless @feature_types;

        print "searching for features of type: " . join(", ", @feature_types) . "\n" if $verbose && !$quiet;
        # get the stream of the right features from the Bio::DB
        my $iterator = $db->get_seq_stream( -seq_id => $segName,
                                            -type   => \@feature_types);


        # make the flattener, which converts bioperl features to arrayrefs
        my $flattener = Bio::JBrowse::BioperlFlattener->new(
                            $trackCfg->{"track"},
                            $mergedTrackCfg,
                            [],
                            [],
                        );

        # start loading the track
        $track->startLoad(
             $segName,
             $nclChunk,
             [ {
                 attributes  => $flattener->featureHeaders,
                 isArrayAttr => { Subfeatures => 1 },
               },
               {
                 attributes  => $flattener->subfeatureHeaders,
                 isArrayAttr => {},
               },
             ],
            );


        # make a sorting object, incrementally sorts the
        # features according to the passed callback
        my $sorter =  do {
            my $startCol = Bio::JBrowse::BioperlFlattener->startIndex;
            my $endCol   = Bio::JBrowse::BioperlFlattener->endIndex;
            Bio::JBrowse::ExternalSorter->new(
                sub ($$) {
                    $_[0]->[$startCol] <=> $_[1]->[$startCol]
                  ||
                    $_[1]->[$endCol]   <=> $_[0]->[$endCol]
                },
                $sortMem
            );
        };

        # go through the features and put them in the sorter
        my $featureCount = 0;
        while( my $feature = $iterator->next_seq ) {

            # load the feature's name record into the track
            if( my $namerec = $flattener->flatten_to_name( $feature, $segName ) ) {
                $track->nameHandler->addName( $namerec );
            }

            # load the flattened feature itself into the sorted, so we
            # can load the actual feature data in sorted order below
            my $row = $flattener->flatten_to_feature( $feature );
            $sorter->add( $row );
            $featureCount++;
        }
        $sorter->finish();

        print "got $featureCount features for $trackCfg->{track}\n" unless $quiet;
        next unless $featureCount > 0;

        # iterate through the sorted features in the sorter and
        # write them out
        while( my $row = $sorter->get ) {
            $track->addSorted( $row );
        }

        # finally, write the entry in the track list for the track we
        # just made
        $gdb->writeTrackEntry( $track );
    }
}

exit;

#############

sub assemble_track_config {
    my ( $global_config, $track_config ) = @_;

    # merge the config
    my %cfg = (
        %{$config->{"TRACK DEFAULTS"}},
        %$track_config
        );

    # rename some of the config variables
    my %renamed_keys = qw(
        class               className
        subfeature_classes  subfeatureClasses
        urlTemplate         linkTemplate
    );
    for ( keys %cfg ) {
        if( my $new_keyname = $renamed_keys{ $_ } ) {
            $cfg{ $new_keyname } = delete $cfg{ $_ };
        }
    }

    # move some of the config variables to a nested 'style' hash
    my %style_keys = map { $_ => 1 } qw(
        subfeatureClasses
        arrowheadClass
        className
        histCss
        featureCss
        linkTemplate
    );
    for ( keys %cfg ) {
        if( $style_keys{$_} ) {
            $cfg{style}{$_} = delete $cfg{$_};
        }
    }

    return \%cfg;
}
