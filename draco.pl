#!/usr/bin/perl

use strict;
use warnings;
use Time::Piece;

use HTTP::Tiny;
use JSON::MaybeXS;

# For wrapping comment blocks.
use Unicode::LineBreak;
my $lb = Unicode::LineBreak->new(ColMax => 76); # Default is 76.

# Printing UTF-8 to STDOUT.
binmode(STDOUT, "encoding(UTF-8)");

die "usage: draco [-dhv] <url>\n" unless scalar @ARGV;

my $DEBUG;
my $VERSION = "v0.2.2";
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

# This is the start time.
my $start_time = time;
my $last_log = $start_time;

# $url contains the reddit post. Raise the limit to 500 comments which
# is the maximum reddit allows.
my $url = shift @ARGV;
my $json_url = "${url}.json?limit=500&sort=top";

my $http = HTTP::Tiny->new( verify_SSL => 1 );

# Fetch the post.
print_time() if $DEBUG;
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

# Start the Org document.
print "#+", "STARTUP:content\n";

# Print the date.
my $current_date = Time::Piece->new->strftime('%+');
print "#+", "DATE: $current_date\n";
print "\n";

# Print the post title & it's link.
print "* ", "[[$post->{url}][$post->{title}]]\n";

# Add various details to :PROPERTIES:.
print ":PROPERTIES:\n";
# Include the created date, archive date & total top-level comments in
# properties.
print ":CREATED_UTC: ",
    Time::Piece->strptime($post->{created_utc}, '%s')
    ->strftime('%+'), "\n";

print ":ARCHIVE_DATE: $current_date\n";
print ":TOTAL_TOP_LEVEL_COMMENTS: ", scalar($comments->@*), "\n";
foreach my $detail (qw( subreddit created_utc author permalink
                        upvote_ratio ups downs score )) {
    print ":${detail}: =$post->{$detail}=\n"
        if scalar $post->{$detail};
}
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
$counter{iterate_over_comments_call} = 0;

print_time() if $DEBUG;
print STDERR "iterating over top-level comments.\n" if $DEBUG;
# Iterate over top-level comments. The second argument is level
# (depth), it should be 0 for top-level comments.
iterate_over_comments($comments, 0);
print_time() if $DEBUG;

# Print important stats.
print STDERR "\n" if $DEBUG;
print STDERR "total http calls: ",
    scalar @http_calls, "\n" if $DEBUG;
print STDERR "total top-level comments: ",
    scalar($comments->@*), "\n" if $DEBUG;
print STDERR "total shell comments: ",
    scalar @shell_comments, "\n" if $DEBUG and scalar @shell_comments;
print STDERR "total print_comment_chain calls: ",
    $counter{print_comment_chain_call}, "\n" if $DEBUG;
print STDERR "total iterate_over_comments calls: ",
    $counter{iterate_over_comments_call}, "\n" if $DEBUG;

# This is equivalent to "continue this thread ->" we see on
# old.reddit.com threads.
print STDERR "total comments skipped due to more: ",
    $counter{skipped_due_to_more}, "\n" if $DEBUG;

sub print_time {
    print STDERR "    ";
    print STDERR "time since [start, last log]: [", time - $start_time,
        ", ", time - $last_log, "] seconds\n";
    $last_log = time;
}

sub get_response {
    my $url = shift @_;
    my $response = $http->get($url);
    push @http_calls, $url;
    die "Unexpected response - $response->{status}: $response->{reason} : $url"
        unless $response->{success};
    return $response;
}

# First argument requires $comments & second is the level (depth).
sub iterate_over_comments {
    my $comments = shift @_;
    my $level = shift @_;

    $counter{iterate_over_comments_call}++;

    foreach my $comment ($comments->@*) {
        my $comment_data = $comment->{data};

        # There are 3 kind of comments.
        #
        # 1. normal comments (includes top-level comments & replies).
        # 2. comments hidden under "load more comments".
        # 3. comments hidden under "continue this thread".

        # We will be dealing with them in reverse order, i.e. 3rd ->
        # 2nd -> 1st.

        # This comment we are skipping is the third kind of comment,
        # i.e. comment hidden under "continue this thread". We can't
        # parse it yet.
        if ($comment->{kind} eq "more"
            and $comment_data->{id} eq "_") {
            $counter{skipped_due_to_more}++;
            next;
        }

        # These are second kind of comments, i.e. comments hidden
        # under "load more comments". We can get it by making another
        # HTTP call. This is skipped by default & user has to pass
        # `FETCH_ALL' to enable it.
        unless ($comment_data->{author}) {
            push @shell_comments, $comment_data->{id};

            # Don't proceed unless user has set `FETCH_ALL'.
            next unless $ENV{FETCH_ALL};

            unless ( eval {
                # Reddit doesn't like this kind of url:
                #     http://<reddit>/<post_id>//<comment_id>.json
                #
                # It wants this kind of url:
                #     http://<reddit>/<post_id>/<comment_id>.json
                #
                # Notice the extra '/' in first url.
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

                # Now this is like a normal comment chain, i.e. first
                # kind of comment. We just have to iterate over it &
                # pass to print_comment_chain, iterate_over_comments
                # will handle it.
                iterate_over_comments($comments, $level);
                return 1;
            } ) {
                my $err = $@;
                print STDERR "parsing `$comment_data->{id}' failed: $err\n";
            }

            # This comment thread has been parsed, move on to the text
            # one.
            next;
        }

        # This is first kind of comment, we can pass it directly to
        # print_comment_chain.
        print_comment_chain($comment_data, $level);
    }
}


# print_comment_chain will print the whole chain of comment while
# accounting for level. It can only parse the first kind of comment,
# i.e. top-level comments & their replies. To learn about kinds of
# comments, check iterate_over_comments() subroutine.
sub print_comment_chain {
    # This was earlier called $comment & was changed to $comment_data
    # to prevent confusion because it is $comment->{data}.
    my $comment_data = shift @_;
    my $level = shift @_;

    $counter{print_comment_chain_call}++;

    print "*" x ($level + 2), " ", "$comment_data->{author}";
    print " [S]" if $comment_data->{is_submitter};
    print "\n";

    # Print comment details.
    print ":PROPERTIES:\n";
    print ":CREATED_UTC: ",
        Time::Piece->strptime($comment_data->{created_utc}, '%s')
          ->strftime('%+'), "\n";
    foreach my $detail (qw( created_utc author permalink upvote_ratio
                            ups downs score edited stickied
                            controversiality )) {
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
        iterate_over_comments($comment_data->{replies}->{data}->{children},
                              $level + 1);
    }
}
