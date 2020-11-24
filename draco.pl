#!/usr/bin/perl

use strict;
use warnings;

use HTTP::Tiny;
use JSON::MaybeXS;

use POSIX qw(strftime);

# For wrapping comment blocks.
use Unicode::LineBreak;
my $lb = Unicode::LineBreak->new(ColMax => 76); # Default is 76.

# Printing UTF-8 to STDOUT.
binmode(STDOUT, "encoding(UTF-8)");

die "usage: draco [-dhv] <url>\n" unless scalar @ARGV;

my $DEBUG;
my $VERSION = "v0.2.1";
# Dispatch table to be parsed before url.
my %dispatch = (
    '-v'  => sub { print "Draco $VERSION\n"; exit; },
    '-d'  => sub { $DEBUG = 1; print STDERR "draco: debug on.\n"; },
    '-h'  => sub { print qq{Draco $VERSION

Options:
    -d
        Turn on debug messages. Debug messages will be printed to
        STDERR.
    -h
        Print this help.
    -v
        Print version.

Environment Variables:
    FETCH_ALL
        Fetch all comments. This will make multiple HTTP calls to
        reddit. This doesn't fetch *all* the comments.
};
                   exit;
               },
);
if (exists $dispatch{$ARGV[0]}) {
    # shift @ARGV to get $url in next shift.
    $dispatch{shift @ARGV}->();
}

# $url contains the reddit post. Raise the limit to 500 comments which
# is the maximum reddit allows.
my $url = shift @ARGV;
my $json_url = "${url}.json?limit=500&sort=top";

my $http = HTTP::Tiny->new( verify_SSL => 1 );

# Fetch the post.
print STDERR "fetching `$json_url'.\n" if $DEBUG;
my $response = get_response($json_url);

# Decode json.
print STDERR "decoding json response.\n" if $DEBUG;
my $json_data = decode_json($response->{content});

# $post contains post data
my $post = $json_data->[0]->{data}->{children}->[0]->{data};

# $comments contains comment data. We are interested in: replies,
# author, body, created_utc & permalink.
my $comments = $json_data->[1]->{data}->{children};

# Print total top-level comments.
print STDERR "total top-level comments: ",
    scalar($comments->@*), "\n" if $DEBUG;

# Start the Org document.
print "#+", "STARTUP:content\n";

# Print the date.
my $date = strftime '%+', localtime();
print "#+", "DATE: $date\n";
print "\n";

# Print the post title & it's link.
print "* ", "[[$post->{url}][$post->{title}]]\n";

# Add various details to :PROPERTIES:.
print ":PROPERTIES:\n";
foreach my $detail (qw( subreddit created_utc author permalink
                        upvote_ratio ups downs score )) {
    print ":${detail}: =$post->{$detail}=\n"
        if scalar $post->{$detail};
}
# Include the archive date & total top-level comments in properties.
print ":ARCHIVE_DATE: $date\n";
print ":TOTAL_TOP_LEVEL_COMMENTS: ", scalar($comments->@*), "\n";
print ":END:\n";

# Add selftext if present.
print "\n#+BEGIN_SRC markdown\n",
    # Break the text at 76 column & add 2 space before every new line.
    "  ", $lb->break($post->{selftext}) =~ s/\n/\n\ \ /gr, "\n",
    "#+END_SRC\n"
    if scalar $post->{selftext};

my (@http_calls, @shell_comments, %counter);
$counter{skipped_due_to_more} = 0;
$counter{print_comment_chain_call} = 0;

# Iterate over top-level comments.
foreach my $comment ($comments->@*) {
    if ($comment->{kind} eq "more"
        and $comment->{data}->{id} eq "_") {
        $counter{skipped_due_to_more}++;
        next;
    }
    print_comment_chain($comment->{data}, 0);
}

print STDERR "total http calls: ",
    scalar @http_calls, "\n" if $DEBUG;
print STDERR "total shell comments: ",
    scalar @shell_comments, "\n" if $DEBUG and scalar @shell_comments;
print STDERR "total print_comment_chain calls: ",
    $counter{print_comment_chain_call}, "\n" if $DEBUG;

# This is equivalent to "continue this thread ->" we see on
# old.reddit.com threads.
print STDERR "total comments skipped due to more: ",
    $counter{skipped_due_to_more}, "\n" if $DEBUG;

sub get_response {
    my $url = shift @_;
    my $response = $http->get($url);
    push @http_calls, $url;
    die "Unexpected response - $response->{status}: $response->{reason} : $url"
        unless $response->{success};
    return $response;
}

# There are 3 kind of comments.
#
# 1. normal comments (includes top-level comments).
# 2. comments hidden under "load more comments".
# 3. comments hidden under "continue this thread".

# print_comment_chain will print the whole chain of comment while
# accounting for level.
sub print_comment_chain {
    # This was earlier called $comment & was changed to $comment_data
    # to prevent confusion because it is $comment->{data}.
    my $comment_data = shift @_;
    my $level = shift @_;

    $counter{print_comment_chain_call}++;

    # $comment_data->{author} not being present means that it's a
    # comment hidden under "load more comments". We can get it by
    # making another HTTP call.
    unless ($comment_data->{author}) {
        push @shell_comments, $comment_data->{id};
        return unless $ENV{FETCH_ALL};
        unless ( eval {
            # It'll fail if we fetch "${url}/$comment_data->{id}.json"
            # & ${url} already has "/" at the end. So, we check if "/"
            # is present, if not then we add it.
            my $json_url = $url;
            $json_url .= "/" unless substr $url, -1 eq "/";
            $json_url .= "$comment_data->{id}.json?limit=500&sort=top";

            # Fetch the comment.
            my $response = get_response($json_url);

            # Decode json.
            my $json_data = decode_json($response->{content});

            # $comments contains comment data. We are interested in: replies,
            # author, body, created_utc & permalink.
            my $comments = $json_data->[1]->{data}->{children};

            foreach my $comment ($comments->@*) {
                if ($comment->{kind} eq "more"
                    and $comment->{data}->{id} eq "_") {
                    $counter{skipped_due_to_more}++;
                    next;
                }
                print_comment_chain($comment->{data}, $level);
            }

            return 1;
        } ) {
            my $err = $@;
            print STDERR "parsing `$comment_data->{id}' failed: $err\n";
        }

        # This comment thread has been parsed, move on to the text
        # one.
        return;
    }

    print "*" x ($level + 2), " ", "$comment_data->{author}";
    print " [S]" if $comment_data->{is_submitter};
    print "\n";

    # Print comment details.
    print ":PROPERTIES:\n";
    foreach my $detail (qw( created_utc author permalink upvote_ratio
                            ups downs score edited is_submitter
                            stickied controversiality )) {
        print ":${detail}: =$comment_data->{$detail}=\n"
            if scalar $comment_data->{$detail};
    }
    print ":END:\n";

    print "\n#+BEGIN_SRC markdown\n",
        # Break the text at 76 column & add 2 space before every new
        # line.
        "  ", $lb->break($comment_data->{body}) =~ s/\n/\n\ \ /gr, "\n",
        "#+END_SRC\n";

    # If the comment has replies then iterate over those too.
    if (scalar $comment_data->{replies}) {
        foreach my $reply ($comment_data->{replies}->{data}->{children}->@*) {
            if ($reply->{kind} eq "more"
                and $reply->{data}->{id} eq "_") {
                $counter{skipped_due_to_more}++;
                next;
            }
            print_comment_chain($reply->{data}, $level + 1);
        }
    }
}
