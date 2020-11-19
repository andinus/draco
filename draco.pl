#!/usr/bin/perl

use strict;
use warnings;

use HTTP::Tiny;
use JSON::MaybeXS;

# For wrapping comment blocks.
use Text::Wrapper;
my $wrapper = Text::Wrapper->new(columns => 72 - 1, body_start => '');

my $VERSION = "v0.1.0";

# Priting UTF-8 to STDOUT.
binmode(STDOUT, "encoding(UTF-8)");

die "usage: draco <url>\n" unless scalar @ARGV;

# $url contains the reddit post.
my $url = shift @ARGV;
my $json_url = "${url}.json";

my $http = HTTP::Tiny->new( verify_SSL => 1 );

# Fetch the post.
my $response = $http->get($json_url);
die "Unexpected response - $response->{status}: $response->{reason}"
    unless $response->{success};

# Decode json.
my $json_data = decode_json($response->{content});

# $post contains post data
my $post = $json_data->[0]->{data}->{children}->[0]->{data};

# Start the Org document.
print "#+", "STARTUP:content\n";

# Print the post title.
print "* ", "$post->{title}\n";

# Add various details to :PROPERTIES:.
print ":PROPERTIES:\n";
foreach my $detail (qw( subreddit created_utc author permalink
                        upvote_ratio ups downs score )) {
    print ":${detail}: =$post->{$detail}=\n"
        if scalar $post->{$detail};
}
print ":END:\n";

# Add selftext/url if present.
print "\n#+BEGIN_SRC markdown\n",
    " ", $wrapper->wrap($post->{selftext}) =~ s/\n/\n\ /gr,
    "#+END_SRC\n"
    if scalar $post->{selftext};
print "$post->{url}\n" if scalar $post->{selftext};

# $comments contains comment data. We are interested in: replies,
# author, body, created_utc & permalink.
my $comments = $json_data->[1]->{data}->{children};
# Iterate over top-level comments.
foreach my $comment ($comments->@*) {
    print_comment_chain($comment->{data}, 0);
}

# print_comment_chain will print the whole chain of comment while
# accounting for level.
sub print_comment_chain {
    my $comment = shift @_;
    my $level = shift @_;

    print "*" x ($level + 2), " ", "$comment->{author}\n";

    # Print comment details.
    print ":PROPERTIES:\n";
    foreach my $detail (qw( created_utc author permalink upvote_ratio
                            ups downs score edited is_submitter
                            stickied controversiality )) {
        print ":${detail}: =$comment->{$detail}=\n"
            if scalar $comment->{$detail};
    }
    print ":END:\n";

    print "\n#+BEGIN_SRC markdown\n",
        " ", $wrapper->wrap($comment->{body}) =~ s/\n/\n\ /gr,
        "#+END_SRC\n";

    # If the comment has replies then iterate over those too.
    if (scalar $comment->{replies}) {
        foreach my $reply ($comment->{replies}->{data}->{children}->@*) {
            print_comment_chain($reply->{data}, $level + 1);
        }
    }
}
