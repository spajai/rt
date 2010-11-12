# BEGIN BPS TAGGED BLOCK {{{
#
# COPYRIGHT:
#
# This software is Copyright (c) 1996-2010 Best Practical Solutions, LLC
#                                          <jesse@bestpractical.com>
#
# (Except where explicitly superseded by other copyright notices)
#
#
# LICENSE:
#
# This work is made available to you under the terms of Version 2 of
# the GNU General Public License. A copy of that license should have
# been provided with this software, but in any event can be snarfed
# from www.gnu.org.
#
# This work is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
# 02110-1301 or visit their web page on the internet at
# http://www.gnu.org/licenses/old-licenses/gpl-2.0.html.
#
#
# CONTRIBUTION SUBMISSION POLICY:
#
# (The following paragraph is not intended to limit the rights granted
# to you to modify and distribute this software under the terms of
# the GNU General Public License and is only of importance to you if
# you choose to contribute your changes and enhancements to the
# community by submitting them to Best Practical Solutions, LLC.)
#
# By intentionally submitting any modifications, corrections or
# derivatives to this work, or any other work intended for use with
# Request Tracker, to Best Practical Solutions, LLC, you confirm that
# you are the copyright holder for those contributions and you grant
# Best Practical Solutions,  LLC a nonexclusive, worldwide, irrevocable,
# royalty-free, perpetual, license to use, copy, create derivative
# works based on those contributions, and sublicense and distribute
# those contributions and any derivatives thereof.
#
# END BPS TAGGED BLOCK }}}

=head1 NAME

  RT::Search::Googleish

=head1 SYNOPSIS

=head1 DESCRIPTION

Use the argument passed in as a "Google-style" set of keywords

=head1 METHODS

=cut

package RT::Search::Googleish;

use strict;
use warnings;
use base qw(RT::Search);

use Regexp::Common qw/delimited/;

# Only a subset of limit types AND themselves together.  "queue:foo
# queue:bar" is an OR, but "subject:foo subject:bar" is an AND
our %AND = (
    content => 1,
    subject => 1,
);

sub _Init {
    my $self = shift;
    my %args = @_;

    $self->{'Queues'} = delete( $args{'Queues'} ) || [];
    $self->SUPER::_Init(%args);
}

sub Describe {
    my $self = shift;
    return ( $self->loc( "Keyword and intuition-based searching", ref $self ) );
}

sub Prepare {
    my $self = shift;
    my $tql  = $self->QueryToSQL( $self->Argument );

    $RT::Logger->debug($tql);

    $self->TicketsObj->FromSQL($tql);
    return (1);
}

sub QueryToSQL {
    my $self = shift;
    my $query = shift || $self->Argument;

    my %limits;
    $query =~ s/^\s*//;
    while ($query =~ /^\S/) {
        if ($query =~ s/^
                        (?:
                            (\w+)  # A straight word
                            (?:\.  # With an optional .foo
                                ($RE{delimited}{-delim=>q['"]}
                                |\w+
                                ) # Which could be ."foo bar", too
                            )?
                        )
                        :  # Followed by a colon
                        ($RE{delimited}{-delim=>q['"]}
                        |\S+
                        ) # And a possibly-quoted foo:"bar baz"
                        \s*//ix) {
            my ($type, $extra, $value) = ($1, $2, $3);
            ($value, my ($quoted)) = $self->Unquote($value);
            $extra = $self->Unquote($extra) if defined $extra;
            $self->Dispatch(\%limits, $type, $value, $quoted, $extra);
        } elsif ($query =~ s/^($RE{delimited}{-delim=>q['"]}|\S+)\s*//) {
            # If there's no colon, it's just a word or quoted string
            my($val, $quoted) = $self->Unquote($1);
            $self->Dispatch(\%limits, $self->GuessType($val, $quoted), $val, $quoted);
        }
    }
    $self->Finalize(\%limits);

    my @clauses;
    for my $subclause (sort keys %limits) {
        my $op = $AND{lc $subclause} ? "AND" : "OR";
        push @clauses, "( ".join(" $op ", @{$limits{$subclause}})." )";
    }

    return join " AND ", @clauses;
}

sub Dispatch {
    my $self = shift;
    my ($limits, $type, $contents, $quoted, $extra) = @_;
    $contents =~ s/(['\\])/\\$1/g;
    $extra    =~ s/(['\\])/\\$1/g if defined $extra;

    my $method = "Handle" . ucfirst(lc($type));
    $method = "HandleDefault" unless $self->can($method);
    my ($key, $tsql) = $self->$method($contents, $quoted, $extra);
    push @{$limits->{$key}}, $tsql;
}

sub Unquote {
    # Given a word or quoted string, unquote it if it is quoted,
    # removing escaped quotes.
    my $self = shift;
    my ($token) = @_;
    if ($token =~ /^$RE{delimited}{-delim=>q['"]}{-keep}$/) {
        my $quote = $2 || $5;
        my $value = $3 || $6;
        $value =~ s/\\(\\|$quote)/$1/g;
        return wantarray ? ($value, 1) : $value;
    } else {
        return wantarray ? ($token, 0) : $token;
    }
}

sub Finalize {
    my $self = shift;
    my ($limits) = @_;

    # Apply default "active status" limit if we don't have any status
    # limits ourselves
    if (not $limits->{status}
        and RT::Config->Get('OnlySearchActiveTicketsInSimpleSearch', $self->TicketsObj->CurrentUser)) {
        $limits->{status} = [map {s/(['\\])/\\$1/g; "Status = '$_'"} RT::Queue->ActiveStatusArray()];
    }

    # Respect the "only search these queues" limit if we didn't
    # specify any queues ourselves
    if (not $limits->{queue}) {
        for my $queue ( @{ $self->{'Queues'} } ) {
            my $QueueObj = RT::Queue->new( $self->TicketsObj->CurrentUser );
            next unless $QueueObj->Load($queue);
            my $name = $QueueObj->Name;
            $name =~ s/(['\\])/\\$1/g;
            push @{$limits->{queue}}, "Queue = '$name'";
        }
    }
}

sub GuessType {
    my $self = shift;
    my ($val, $quoted) = @_;

    return "subject" if $quoted;

    my $Queue = RT::Queue->new( $self->TicketsObj->CurrentUser );
    my $User = RT::User->new( $self->TicketsObj->CurrentUser );
    if ($val =~ /^\d+$/) {
        # Simple numeric => id or subject
        return "number";
    } elsif ($val =~ /\w+\@\w+/) {
        # email => requestor address
        return "requestor";
    } elsif ( $Queue->IsValidStatus($val) ) {
        # a valid status
        return "status";
    } elsif ($Queue->Load($val) && $Queue->Id ) {
        # Matches a queue name (or id, but we dealt with that above)
        return "queue";
    } elsif ($User->Load($val) && $User->Id && $User->Privileged ) {
        # Matches a privileged username
        return "owner";
    } else {
        # Fall through to the default
        return "default";
    }

}

sub HandleDefault   { return subject   => "Subject LIKE '$_[1]'"; }
sub HandleSubject   { return subject   => "Subject LIKE '$_[1]'"; }
sub HandleFulltext  { return content   => "Content LIKE '$_[1]'"; }
sub HandleContent   { return content   => "Content LIKE '$_[1]'"; }
sub HandleId        { return id        => "Id = '$_[1]'";         }
sub HandleStatus    { return status    => "Status = '$_[1]'";     }
sub HandleOwner     { return owner     => "Owner = '$_[1]'";      }
sub HandleRequestor { return requestor => "Requestor LIKE '$_[1]'";  }
sub HandleQueue     { return queue     => "Queue = '$_[1]'";      }

sub HandleNumber    { return number    => "(Id = '$_[1]' OR Subject LIKE '$_[1]')"; }
sub HandleCf        { return "cf.$_[3]" => "CF.'$_[3]' LIKE '$_[1]'"; }

RT::Base->_ImportOverlays();

1;
