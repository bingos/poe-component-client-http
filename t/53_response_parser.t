#!/usr/bin/perl
# $Id$
# vim: filetype=perl

# Generic response parser testing, especially for cases where
# POE::Component::Client::HTTP generates the wrong response.

use warnings;
use strict;

use IO::Socket::INET;
use Socket '$CRLF';
use HTTP::Request::Common 'GET';

sub DEBUG () { 0 }

# The number of tests must match scalar(@tests).
use Test::More tests => 3;

use POE;
use POE::Component::Client::HTTP;
use POE::Component::Server::TCP;

my $test_number = 0;

my @server_ports;

# A list of test responses, each paired with a subroutine to check
# whether the response was parsed.

my @tests = (
  # Unknown transfer encodings must be preserved.
  [
    (
      "HTTP/1.1 200 OK$CRLF" .
      "Connection: close$CRLF" .
      "Transfer-Encoding: poit,narf,chunked$CRLF" .
      "Content-type: text/plain$CRLF" .
      $CRLF .
      "7$CRLF" .
      "chunk 1$CRLF" .
      "0$CRLF"
    ),
    sub {
      my $response = shift;
      ok(
        $response->code() == 200 &&
        $response->header("Transfer-Encoding") eq "poit, narf",
        "unknown transfer encodings preserved"
      );
    },
  ],
  # An HTTP/0.9 response.
  [
    (
      "<html><head><title>Test</title></head>" .
      "<body>HTTP/0.9 Allows documents with no status and no headers!</body>" .
      "</html>"
    ),
    sub {
      my $response = shift;
      ok(
        $response->code() == 200 &&
        $response->content() =~ /Allows documents/,
        "HTTP 0.9 supports no status and no headers"
      );
    },
  ],
  # A response with no known transfer encoding.
  [
    (
      "HTTP/1.1 200 OK$CRLF" .
      "Connection: close$CRLF" .
      "Transfer-Encoding: zort,poit,narf$CRLF" .
      "Content-type: text/plain$CRLF" .
      $CRLF .
      "7$CRLF" .
      "chunk 1$CRLF" .
      "0$CRLF"
    ),
    sub {
      my $response = shift;
      ok(
        $response->code() == 200 &&
        $response->header("Transfer-Encoding") eq "zort, poit, narf",
        "no known transfer encodings"
      );
    },
  ],
);

# Spawn one server per test response.
{
  foreach (@tests) {
    POE::Component::Server::TCP->new(
      Address             => "127.0.0.1",
      Port                => 0,
      Started             => \&register_port,
      ClientInputFilter   => "POE::Filter::Line",
      ClientOutputFilter  => "POE::Filter::Stream",
      ClientInput         => \&parse_next_request,
    );
  }

  sub register_port {
    push(
      @server_ports,
      (sockaddr_in($_[HEAP]->{listener}->getsockname()))[0]
    );
  }

  sub parse_next_request {
    my $input = $_[ARG0];

    DEBUG and diag "got line: [$input]";
    return if $input ne "";

    my $response = $tests[$test_number][0];
    $_[HEAP]->{client}->put($response);

    $response =~ s/$CRLF/{CRLF}/g;
    DEBUG and diag "sending: [$response]";

    $_[KERNEL]->yield("shutdown");
  }
}

# Spawn the HTTP user-agent component.
POE::Component::Client::HTTP->spawn();

# Create a client session to drive the HTTP component.
POE::Session->create(
  inline_states => {
    _start => sub {
      $_[KERNEL]->yield("run_next_test");
    },
    run_next_test => sub {
      my $port    = $server_ports[$test_number];
      $_[KERNEL]->post(
        weeble => request => response =>
        GET "http://127.0.0.1:${port}/"
      );
    },
    response => sub {
      my $response = $_[ARG1][0];
      my $test     = $tests[$test_number][1];
      $test->($response);

      $_[KERNEL]->yield("run_next_test") if ++$test_number < @tests;
    },
    _stop => sub { exit },  # Nasty but expedient.
  }
);

POE::Kernel->run();
exit;
