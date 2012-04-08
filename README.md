# Installing JBrowse

To install JBrowse, see the main JBrowse wiki at http://gmod.org/wiki/JBrowse.

The rest of this file is aimed primarily at developers.

# Running the developer test suites

## Running Server-side Perl Unit and Integration Tests

Tests for the server-side Perl code.  You must have the JBrowse Perl
module prerequisites installed for them to work.  Run with:

    prove -lr t

## Running JavaScript Unit Tests (with node and node-tap)

You need to have the node.js `node` executable in your path.  Run the
tests with `prove`, like:

    prove -lr tests/js_tests

## Running Client Integration Tests (with Selenium)

Integration tests for the client-side app.  You need to have Python
eggs for `selenium` and `nose` installed.  Run the tests with:

    nosetests

# Using the embedded JavaScript documentation

The embedded documentation is written in JSDoc.  See
http://code.google.com/p/jsdoc-toolkit.

Running `bin/jbdoc ArrayRepr` will open your browser with
documentation about ArrayRepr.js.

See [http://code.google.com/p/jsdoc-toolkit/w/list] for a list of JSDoc
tags.
