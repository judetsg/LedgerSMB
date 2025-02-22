
package LedgerSMB::Database::Change;

=head1 NAME

LedgerSMB::Database::Change - Database change scripts for LedgerSMB

=head1 DESCRIPTION

Implements infrastructure to apply "schema-deltas" (schema-changes)
exactly once. Meaning that if a change has been applied succesfully,
it won't be applied again.

Please note that the criterion 'has been applied' is determined by
the SHA512 of the content of the schema change file.  This leaves no
room for fixing the content of the schema change file as changing
the content means the schema change will be applied in all upgrades,
even if the older variant was succesfully applied (because the bug
which the fixed content addresses wasn't triggered on some upgrades).

To address the immutability concern, the following extension to the
immutability has been devised.  When a schema change file must be
changed/fixed, the original must be copied to a new file with an
added suffix of an at-sign and a sequence number. Here's an example:

   sql/changes/1.4/abc.sql -copy-> sql/changes/1.4/abc.sql@1
   sql/changes/1.4/abc.sql (changed).

The new file (C<abc.sql@1>) must not be added to the change mechanism's
LOADORDER file. If another change to C<abc.sql> is required, the
following happens:

   sql/changes/1.4/abc.sql -copy-> sql/changes/1.4/abc.sql@2
   sql/changes/1.4/abc.sql (changed again).

On upgrade, this module will detect that older versions of the file
exist and have been succesfully applied.  If that's the case, the
schema change file will be considered to be applied.


Note that this functionality isn't specific to LedgerSMB and mostly
mirrors PGObject::Util::DBChange and originates from that code.

=cut

use strict;
use warnings;

use Cwd;
use Digest::SHA;
use File::Basename;
use File::Find;

=head1 SYNOPSIS

my $dbchange = LedgerSMB::Database::Change->new(path => $path,
                                      properties => $properties);

my $content = $dbchange->content()
my $sha = $dbchange->sha();
my $content_wrapped = $dbchange->content_wrap($before, $after);

=head1 METHODS

=head2 new($path, $properties)

Constructor.

$properties is optional and a hashref with any of the following keys set:

=over

=item no_transactions

Do not group statements into a single transaction.

Note: as DBI/DBD::Pg never runs statements outside of transactions;
  code running in C<no_transactions> mode will run each statement
  in its own transaction.

=item reload_subsequent

If this one has changed, then reload further modules

=back

=cut

sub new {
    my ($package, $path, $init_properties) = @_;
    my $self = bless { _path => $path }, $package;
    my @prop_names = qw(no_transactions reload_subsequent);
    $self->{properties} = { map { $_ => $init_properties->{$_} } @prop_names };
    return $self;
}

=head2 path

Path to the module (read-only accessor)

=cut

sub path {
    my ($self) = @_;
    return $self->{_path};
}

=head2 content($raw)

SQL content read from the change file.

=cut

sub _slurp {
    my ($path) = @_;

    local $! = undef;
    open my $fh, '<', $path or
        die 'FileError: ' . Cwd::abs_path($path) . ": $!";
    binmode $fh, 'encoding(:UTF-8)';
    my $content = join '', <$fh>;
    close $fh or die 'Cannot close file ' . $path;

    return $content;
}

sub content {
    my ($self, $raw) = @_;
    unless ($self->{_content}) {
        $self->{_content} = _slurp($self->path);
    }
    return $self->{_content};
}

=head2 sha

sha of sql content, stripped of comments and lines with only whitespace
characters

=cut

sub _normalized_sha {
    my ($content) = @_;

    my $normalized =
        join "\n",
        grep { /\S/ }
        map { s/--.*//r }
        split /\n/, ($content =~ s{/\*.*?\*/}{}gsr);

    return Digest::SHA::sha512_base64($normalized);
}

sub sha {
    my ($self) = @_;

    return $self->{_sha} if $self->{_sha};

    my $content = $self->content(1); # raw
    $self->{_sha} = _normalized_sha($content);
    return $self->{_sha};
}


=head2 is_applied($dbh)

Returns true if the current sha matches one that has been applied.

=cut

sub is_applied {
    my ($self, $dbh) = @_;

    my @shas = ($self->sha);
    my $path = $self->path;
    my $want_old_scripts = sub {
        my $file = $File::Find::name;

        if ($file =~ /^\Q$path@\E/) {
            if (-f $file) {
                push @shas, _normalized_sha(_slurp($file));
            }
        }
    };
    find({ wanted => $want_old_scripts,
           follow => 0,
           no_chdir => 1 }, dirname($path));

    my $sth = $dbh->prepare(
        'SELECT * FROM db_patches WHERE sha = ?'
        );

    my $retval = 0;
    for my $sha (@shas) {
        $sth->execute($sha)
            or die $sth->errstr;
        my $rv = $sth->fetchall_arrayref
            or die $sth->errstr;
        $sth->finish
            or die $sth->errstr;

        $retval = scalar @$rv;
        last if $retval;
    }

    return $retval;
}

=head2 run($dbh)

Runs against the current dbh without tracking, in a single
transaction.

=cut

sub run {
    my ($self, $dbh) = @_;
    return $dbh->do($self->content); # not raw
}

=head2 apply($dbh)

Applies the current file to the db in the current dbh. May issue
one or more C<$dbh->commit()>s; if there's a pending transaction on
a handle, C<$dbh->clone()> can be used to create a separate copy.

Returns no value in particular.

Throws an error in case of failure.

=cut

sub apply {
    my ($self, $dbh) = @_;
    return if $self->is_applied($dbh);

    my @after_params =  ( $self->sha );
    my $no_transactions = $self->{properties}->{no_transactions};

    my @statements = _combine_statement_blocks($self->_split_statements);
    my $last_stmt_rc;
    my ($state, $errstr);

    $dbh->do(q{set client_min_messages = 'warning';});
    $dbh->commit if ! $dbh->{AutoCommit};

    # If we're in auto-commit mode, but we want 1 lengthy transaction,
    # open one.
    $dbh->begin_work if not $no_transactions and $dbh->{AutoCommit};
    for my $stmt (@statements) {
        $last_stmt_rc = $dbh->do($stmt);

        # in case the caller wanted 'transactionless' execution of the
        # statements, either commit or roll back after each statement(group)
        # **when the $dbh isn't itself already set to do so!**

        # Note that we don't need to commit in any case when the caller
        # requested with-transactions processing: all statements are
        # returned in a single block, which means 'single transaction' in
        # all modes.
        if (not $dbh->{AutoCommit} and $no_transactions) {
            if (!$last_stmt_rc) {
                $dbh->rollback;
            }
            else {
                $dbh->commit;
            }
        }
        elsif (not $no_transactions and not $last_stmt_rc) {
            $errstr = $dbh->errstr;
            $state = $dbh->state;
            last;
        }
    }

    # For transactionless processing, due to the commit and rollback
    # above, this starts in a clean transaction.
    # For with-transaction processing, this transaction runs in the
    # same transaction because above no commit was executed and higher up
    # a transaction started with 'begin_work()'

    $last_stmt_rc = $dbh->do(q{
           INSERT INTO db_patches (sha, path, last_updated)
           VALUES (?, ?, now());
        }, undef, $self->sha, $self->path);

    # When there is no auto commit, simulated it by committing after each
    # query
    # When there *is* auto commit, but a single transaction was requested,
    # we called 'begin_work()' above; close that by calling 'commit()' or
    # 'rollback()' here.
    if ((not $dbh->{AutoCommit})
        or (not $no_transactions and $dbh->{AutoCommit})) {
        if (!$last_stmt_rc) {
            $dbh->rollback;
        }
        else {
            $dbh->commit;
        }
    }

    $dbh->do(q{
            INSERT INTO db_patch_log(when_applied, path, sha, sqlstate, error)
            VALUES(now(), ?, ?, ?, ?)
    }, undef, $self->sha, $self->path, $state // 0, $errstr // '');
    $dbh->commit if (! $dbh->{AutoCommit});

    if ($errstr) {
        die 'Error applying upgrade script ' . $self->path . ': ' . $errstr;
    }

    return;
}

# $self->_split_statements()
#
# Returns an array of strings, where each string is one (or multiple)
# statement(s) to be run in a single transaction.

sub _split_statements {
    my ($self) = @_;

    # Early escape when the caller wants all statements to run in a
    # single transaction. No need to split and regroup statements...
    # Just run the entire block.
    return ($self->content)
        if ! $self->{properties}->{no_transactions};

    my $content = $self->content;
    $content =~ s{/\*.*?\*/}{}gs;
    $content =~ s/\s*--.*//g;
    my @statements = ();

    while ($content =~ m/
((?&Statement))
(?(DEFINE)
   (?<BareIdentifier>[a-zA-Z_][a-zA-Z0-9_]*)
   (?<QuotedIdentifier>"[^\"]+")
   (?<SingularIdentifier>(?&BareIdentifier)|(?&QuotedIdentifier)|\*)
   (?<Identifier>(?&SingularIdentifier)(\.(?&SingularIdentifier))*)
   (?<QuotedString>'([^\\']|\\.)*')
   (?<DollarQString>\$(?<_dollar_block>(?&BareIdentifier)?)\$
                      [^\$]* (?: \$(?!\g{_dollar_block}\$) [^\$]*+)*
                      \$\g{_dollar_block}\$)
   (?<String> (?&QuotedString) | (?&DollarQString) )
   (?<Number>[+-]?[0-9]++(\.[0-9]*)? )
   (?<Operator> [=<>#^%?@!&~|\/*+-]+|::)
   (?<Array> \[ (?&WhiteSp)
                (?: (?&ComplexTokenSequence)
                    (?&WhiteSp) )?
             \] )
   (?<WhiteSp>[\s\t\n]*)
   (?<TokenSep>,)
   (?<Token>
           (?&String)
           | (?&Identifier)
           | (?&Number)
           | (?&Operator)
           | (?&TokenSep))
   (?<TokenGroup> \(
                  (?&WhiteSp)
                  (?: (?&ComplexTokenSequence)
                      (?&WhiteSp) )?
                  \) )
   (?<ComplexToken>(?&Token)
                 | (?&TokenGroup)
                 | (?&Array))
   (?<ComplexTokenSequence>
                   (?&ComplexToken)
                   (?: (?&WhiteSp) (?&ComplexToken) )* )
   (?<Statement> (?&BareIdentifier) (?&WhiteSp)
                 (?: (?&ComplexTokenSequence) (?&WhiteSp) )? ; )
)
           /gxms) {
        push @statements, $1;
    }
    return @statements;
}


sub _combine_statement_blocks {
    my @statements = @_;

    my @blocks = ();
    my $cum_stmt = '';
    my $in_transaction = 0;
    for my $stmt (@statements) {
        if ($stmt =~ m/^\s*BEGIN\s*;\s*$/i) {
          $in_transaction = 1;
          next;
       }
        elsif ($stmt =~ m/^\s*COMMIT\s*;\s*$/i) {
          push @blocks, $cum_stmt;
          $cum_stmt = '';
          $in_transaction = 0;
          next;
       }

       if ($in_transaction) {
          $cum_stmt .= $stmt;
       }
       else {
          push @blocks, $stmt;
       }
   }
   return @blocks;
}

=head1 Package Functions

=head2 init($dbh)

Initializes the tracking system

=cut

sub init {
    my ($dbh) = @_;
    return 0 unless needs_init($dbh);
    my $success = $dbh->prepare('
    CREATE TABLE db_patch_log (
       when_applied timestamp primary key,
       path text NOT NULL,
       sha text NOT NULL,
       sqlstate text not null,
       error text
    );
    CREATE TABLE db_patches (
       sha text primary key,
       path text not null,
       last_updated timestamp not null
    );
    ')->execute();
    die "$DBI::state: $DBI::errstr" unless $success;

    return 1;
}

=head2 needs_init($dbh)

Returns true if the tracking system needs to be initialized

=cut

sub needs_init {
    my ($dbh) = @_;
    my $count = $dbh->prepare(q{
        select relname from pg_class
         where relname = 'db_patches'
               and pg_table_is_visible(oid)
    })->execute();
    return !int($count);
}

=head1 TODO

Future versions will allow properties to be specified in comment headers in
the scripts themselves.  This will pose some backwards-compatibility issues and
therefore will be 2.0 material.

=head1 LICENSE AND COPYRIGHT

Copyright (C) 2016-2018 The LedgerSMB Core Team

This file is licensed under the GNU General Public License version 2, or at your
option any later version.  A copy of the license should have been included with
your software.

=cut

1;
