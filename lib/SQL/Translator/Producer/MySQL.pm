package SQL::Translator::Producer::MySQL;

# -------------------------------------------------------------------
# $Id: MySQL.pm,v 1.28 2003-10-15 18:55:11 kycl4rk Exp $
# -------------------------------------------------------------------
# Copyright (C) 2003 Ken Y. Clark <kclark@cpan.org>,
#                    darren chamberlain <darren@cpan.org>,
#                    Chris Mungall <cjm@fruitfly.org>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License as
# published by the Free Software Foundation; version 2.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
# 02111-1307  USA
# -------------------------------------------------------------------

=head1 NAME

SQL::Translator::Producer::MySQL - MySQL-specific producer for SQL::Translator

=head1 SYNOPSIS

Use via SQL::Translator:

  use SQL::Translator;

  my $t = SQL::Translator->new( parser => '...', producer => 'MySQL', '...' );
  $t->translate;

=head1 DESCRIPTION

This module will produce text output of the schema suitable for MySQL.
There are still some issues to be worked out with syntax differences 
between MySQL versions 3 and 4 ("SET foreign_key_checks," character sets
for fields, etc.).

=cut

use strict;
use vars qw[ $VERSION $DEBUG ];
$VERSION = sprintf "%d.%02d", q$Revision: 1.28 $ =~ /(\d+)\.(\d+)/;
$DEBUG   = 0 unless defined $DEBUG;

use Data::Dumper;
use SQL::Translator::Schema::Constants;
use SQL::Translator::Utils qw(debug header_comment);

my %translate  = (
    #
    # Oracle types
    #
    varchar2   => 'varchar',
    long       => 'text',
    CLOB       => 'longtext',

    #
    # Sybase types
    #
    int        => 'integer',
    money      => 'float',
    real       => 'double',
    comment    => 'text',
    bit        => 'tinyint',
);

sub produce {
    my $translator     = shift;
    local $DEBUG       = $translator->debug;
    my $no_comments    = $translator->no_comments;
    my $add_drop_table = $translator->add_drop_table;
    my $schema         = $translator->schema;

    debug("PKG: Beginning production\n");

    my $create; 
    $create .= header_comment unless ($no_comments);
    # \todo Don't set if MySQL 3.x is set on command line
    $create .= "SET foreign_key_checks=0;\n\n";

    for my $table ( $schema->get_tables ) {
        my $table_name = $table->name;
        debug("PKG: Looking at table '$table_name'\n");

        #
        # Header.  Should this look like what mysqldump produces?
        #
        $create .= "--\n-- Table: $table_name\n--\n" unless $no_comments;
        $create .= qq[DROP TABLE IF EXISTS $table_name;\n] if $add_drop_table;
        $create .= "CREATE TABLE $table_name (\n";

        #
        # Fields
        #
        my @field_defs;
        for my $field ( $table->get_fields ) {
            my $field_name = $field->name;
            debug("PKG: Looking at field '$field_name'\n");
            my $field_def = $field_name;

            # data type and size
            my $data_type = $field->data_type;
            my @size      = $field->size;
            my %extra     = $field->extra;
            my $list      = $extra{'list'} || [];
            # \todo deal with embedded quotes
            my $commalist = join( ', ', map { qq['$_'] } @$list );

            #
            # Oracle "number" type -- figure best MySQL type
            #
            if ( lc $data_type eq 'number' ) {
                # not an integer
                if ( scalar @size > 1 ) {
                    $data_type = 'double';
                }
                elsif ( $size[0] >= 12 ) {
                    $data_type = 'bigint';
                }
                elsif ( $size[0] <= 1 ) {
                    $data_type = 'tinyint';
                }
                else {
                    $data_type = 'int';
                }
            }
            elsif ( exists $translate{ $data_type } ) {
                $data_type = $translate{ $data_type };
            }

            @size = () if $data_type eq 'text';

            $field_def .= " $data_type";
            
            if ( lc $data_type eq 'enum' ) {
                $field_def .= '(' . $commalist . ')';
			} 
            elsif ( defined $size[0] && $size[0] > 0 ) {
                $field_def .= '(' . join( ', ', @size ) . ')';
            }

            # MySQL qualifiers
            for my $qual ( qw[ binary unsigned zerofill ] ) {
                my $val = $extra{ $qual || uc $qual } or next;
                $field_def .= " $qual";
            }

            # Null?
            $field_def .= ' NOT NULL' unless $field->is_nullable;

            # Default?  XXX Need better quoting!
            my $default = $field->default_value;
            if ( defined $default ) {
                if ( uc $default eq 'NULL') {
                    $field_def .= ' DEFAULT NULL';
                } else {
                    $field_def .= " DEFAULT '$default'";
                }
            }

            # auto_increment?
            $field_def .= " auto_increment" if $field->is_auto_increment;
            push @field_defs, $field_def;
		}

        #
        # Indices
        #
        my @index_defs;
        for my $index ( $table->get_indices ) {
            push @index_defs, join( ' ', 
                lc $index->type eq 'normal' ? 'INDEX' : $index->type,
                $index->name,
                '(' . join( ', ', $index->fields ) . ')'
            );
        }

        #
        # Constraints -- need to handle more than just FK. -ky
        #
        my @constraint_defs;
        for my $c ( $table->get_constraints ) {
            my @fields = $c->fields or next;

            if ( $c->type eq PRIMARY_KEY ) {
                push @constraint_defs,
                    'PRIMARY KEY (' . join(', ', @fields). ')';
            }
            elsif ( $c->type eq UNIQUE ) {
                push @constraint_defs,
                    'UNIQUE (' . join(', ', @fields). ')';
            }
            elsif ( $c->type eq FOREIGN_KEY ) {
                my $def = join(' ', 
                    map { $_ || () } 'FOREIGN KEY', $c->name 
                );

                $def .= ' (' . join( ', ', @fields ) . ')';

                $def .= ' REFERENCES ' . $c->reference_table;

                if ( my @rfields = $c->reference_fields ) {
                    $def .= ' (' . join( ', ', @rfields ) . ')';
                }

                if ( $c->match_type ) {
                    $def .= ' MATCH ' . 
                        ( $c->match_type =~ /full/i ) ? 'FULL' : 'PARTIAL';
                }

                if ( $c->on_delete ) {
                    $def .= ' ON DELETE '.join( ' ', $c->on_delete );
                }

                if ( $c->on_update ) {
                    $def .= ' ON UPDATE '.join( ' ', $c->on_update );
                }

                push @constraint_defs, $def;
            }
        }

        $create .= join(",\n", map { "  $_" } 
            @field_defs, @index_defs, @constraint_defs
        );

        #
        # Footer
        #
        $create .= "\n)";
#        while ( 
#            my ( $key, $val ) = each %{ $table->options }
#        ) {
#            $create .= " $key=$val" 
#        }
        $create .= ";\n\n";
    }

    return $create;
}

1;

# -------------------------------------------------------------------

=pod

=head1 SEE ALSO

SQL::Translator, http://www.mysql.com/.

=head1 AUTHORS

darren chamberlain E<lt>darren@cpan.orgE<gt>,
Ken Y. Clark E<lt>kclark@cpan.orgE<gt>.

=cut
