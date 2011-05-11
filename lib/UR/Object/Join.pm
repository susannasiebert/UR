package UR::Object::Join;
use strict;
use warnings;

sub resolve_chain_for_property_meta {
    my ($class, $pmeta) = @_;  
    if ($pmeta->via or $pmeta->to) {
        return $class->_resolve_indirect($pmeta);
    }
    else {
        return $class->_resolve_direct($pmeta);
    }
}

sub _resolve_indirect {
    my ($class, $pmeta) = @_;
    my $class_meta = UR::Object::Type->get(class_name => $pmeta->class_name);

    my @joins;
    my $via = $pmeta->via;

    my $to = $pmeta->to;    
    if ($via and not $to) {
        $to = $pmeta->property_name;
    }

    my $via_meta;
    if ($via) {
        $via_meta = $class_meta->property_meta_for_name($via);
        unless ($via_meta) {
            my $property_name = $pmeta->property_name;
            my $class_name = $pmeta->class_name;
            Carp::croak "Can't resolve property '$property_name' of $class_name: No via meta for '$via'?";
        }

        if ($via_meta->to and ($via_meta->to eq '-filter')) {
            return $via_meta->_resolve_join_chain;
        }

        unless ($via_meta->data_type) {
            my $property_name = $pmeta->property_name;
            my $class_name = $pmeta->class_name;
            Carp::croak "Can't resolve property '$property_name' of $class_name: No data type for '$via'?";
        }
        push @joins, $via_meta->_resolve_join_chain();
        
        if (my $where = $pmeta->where) {
            if ($where->[1] eq 'name') {
                @$where = reverse @$where;
            }        
            my $join = pop @joins;
            #my $where_rule = $join->{foreign_class}->define_boolexpr(@$where);               
            unless ($join->{foreign_class}) {
                Carp::confess("No foreign class in " . Data::Dumper::Dumper($join, \@joins));
            }
            my $where_rule = UR::BoolExpr->resolve($join->{foreign_class}, @$where);                
            my $id = $join->{id};
            $id .= ' ' . $where_rule->id;
            push @joins, { %$join, id => $id, where => $where };
        }
    }
    else {
        $via_meta = $pmeta;
    }

    if ($to and $to ne '__self__' and $to ne '-filter') {
        my $to_class_meta = eval { $via_meta->data_type->__meta__ };
        unless ($to_class_meta) {
            Carp::croak("Can't get class metadata for " . $via_meta->data_type
                        . " while resolving property '" . $pmeta->property_name . "' in class " . $pmeta->class_name . "\n"
                        . "Is the data_type for property '" . $via_meta->property_name . "' in class "
                        . $via_meta->class_name . " correct?");
        }

        my $to_meta = $to_class_meta->property_meta_for_name($to);
        unless ($to_meta) {
            my $property_name = $pmeta->property_name;
            my $class_name = $pmeta->class_name;
            Carp::croak "Can't resolve property '$property_name' of $class_name: No '$to' property found on " . $via_meta->data_type;
        }
        push @joins, $to_meta->_resolve_join_chain();
    }
    
    return @joins;
}

my @old = qw/source_class source_property_names foreign_class foreign_property_names source_name_for_foreign foreign_name_for_source is_optional/;
my @new = qw/foreign_class foreign_property_names source_class source_property_names foreign_name_for_source source_name_for_foreign is_optional/;

sub _translate_data_type_to_class_name {
    my ($source_class, $foreign_class) = @_;

    # TODO: allowing "is => 'Text'" instead of is => 'UR::Value::Text' is syntactic sugar
    # We should have an is_primitive flag set on these so we do efficient work.
    my $ur_value_class = 'UR::Value::' . $foreign_class;
    
    my ($ns) = ($source_class =~ /^([^:]+)/);
    my $ns_value_class;
    if ($ns and $ns->can("get")) {
        $ns_value_class = $ns . '::Value::' . $foreign_class;
        if ($ns_value_class->can('__meta__')) {
            $foreign_class = $ns_value_class;
        }
    }

    if (!$foreign_class->can('__meta__')) {
        if ($ur_value_class->can('__meta__')) {
            $foreign_class = $ur_value_class;
        }
        else {
            if ($ns->get()->allow_sloppy_primitives) {
                $foreign_class = 'UR::Value::SloppyPrimitive';
            }
            else {
                Carp::confess("Failed to find a ${ns}::Value::* or UR::Value::* module for primitive type $foreign_class!");
            }
        }
    }

    return $foreign_class;
}

sub _resolve_direct {
    my ($class, $pmeta) = @_;
    my $class_meta = UR::Object::Type->get(class_name => $pmeta->class_name);

    my @joins;

    # not a via/to ...one join for this relationship
    my $source_class = $class_meta->class_name;            
    my $foreign_class = $pmeta->data_type;
    my $where = $pmeta->where;
    if (defined($where) and defined($where->[1]) and $where->[1] eq 'name') {
        @$where = reverse @$where;
    }
    
    if (defined($foreign_class) and not $foreign_class->can('get')) {
        $foreign_class = _translate_data_type_to_class_name($source_class,$foreign_class);
    }
    
    if (defined($foreign_class) and $foreign_class->can('get'))  {
        # there is a class on the other side, either an entity or a value
        my $foreign_class_meta = $foreign_class->__meta__;
        my $property_name = $pmeta->property_name;

        my $id = $source_class . '::' . $property_name;
        if ($where) {
            #my $where_rule = $foreign_class->define_boolexpr(@$where);
            my $where_rule = UR::BoolExpr->resolve($foreign_class, @$where);
            $id .= ' ' . $where_rule->id;
        }

        if ($pmeta->id_by or $foreign_class->isa("UR::Value")) {
            # direct reference (or primitive, which is a direct ref to a value obj)
            my (@source_property_names, @foreign_property_names);
            my ($source_name_for_foreign, $foreign_name_for_source);

            if ($foreign_class->isa("UR::Value")) {
                @source_property_names = ($property_name);
                @foreign_property_names = ('id');

                $source_name_for_foreign = ($property_name);
            }
            elsif (my $id_by = $pmeta->id_by) { 
                my @pairs = $pmeta->get_property_name_pairs_for_join;
                @source_property_names  = map { $_->[0] } @pairs;
                @foreign_property_names = map { $_->[1] } @pairs;
        
                if (ref($id_by) eq 'ARRAY') {
                    # satisfying the id_by requires joins of its own
                    # sms: why is this only done on multi-value fks?
                    foreach my $id_by_property_name ( @$id_by ) {
                        my $id_by_property = $class_meta->property_meta_for_name($id_by_property_name);
                        next unless ($id_by_property and $id_by_property->is_delegated);
                    
                        push @joins, $id_by_property->_resolve_join_chain();
                        $source_class = $joins[-1]->{'foreign_class'};
                        @source_property_names = @{$joins[-1]->{'foreign_property_names'}};
                    }
                }

                $source_name_for_foreign = $pmeta->property_name;
                my @reverse = $foreign_class_meta->properties(reverse_as => $source_name_for_foreign, data_type => $pmeta->class_name);
                my $reverse;
                if (@reverse > 1) {
                    my @reduced = grep { not $_->where } @reverse;
                    if (@reduced != 1) {
                        Carp::confess("Ambiguous results finding reversal for $property_name!" . Data::Dumper::Dumper(\@reverse));
                    }
                    $reverse = $reduced[0];
                }
                else {
                    $reverse = $reverse[0];
                }
                if ($reverse) {
                    $foreign_name_for_source = $reverse->property_name;
                }
            }

            # the foreign class might NOT have a reverse_as, but
            # this records what to reverse in this case.
            $foreign_name_for_source ||= '<' . $source_class . '::' . $source_name_for_foreign;

            push @joins, {
                           id => $id,

                           source_class => $source_class,
                           source_property_names => \@source_property_names,
                           
                           foreign_class => $foreign_class,
                           foreign_property_names => \@foreign_property_names,
                           
                           source_name_for_foreign => $source_name_for_foreign,
                           foreign_name_for_source => $foreign_name_for_source,
                          
                           is_optional => ($pmeta->is_optional or $pmeta->is_many),

                           where => $where,
                         };
        }
        elsif (my $reverse_as = $pmeta->reverse_as) { 
            my $foreign_class = $pmeta->data_type;
            my $foreign_class_meta = $foreign_class->__meta__;
            my $foreign_property_via = $foreign_class_meta->property_meta_for_name($reverse_as);
            unless ($foreign_property_via) {
                Carp::confess("No property '$reverse_as' in class $foreign_class, needed to resolve property '" .
                              $pmeta->property_name . "' of class " . $pmeta->class_name);
            }
            @joins = map { { %$_ } } reverse $foreign_property_via->_resolve_join_chain();
            my $prev_where = $where;
            for (@joins) { 
                @$_{@new} = @$_{@old};

                my $next_where = $_->{where};
                $_->{where} = $prev_where;

                my $id = $_->{source_class} . '::' . $_->{source_name_for_foreign};
                if ($prev_where) {
                    my $where_rule = UR::BoolExpr->resolve($foreign_class, @$where);
                    $id .= ' ' . $where_rule->id;
                }
                $_->{id} = $id; 
        
                $_->{is_optional} = ($pmeta->is_optional || $pmeta->is_many);
                $prev_where = $next_where;
            }
            if ($prev_where) {
                Carp::confess("final join needs placement! " . Data::Dumper::Dumper($prev_where));
            }

        } 
        else {
            $pmeta->error_message("Property $id has no 'id_by' or 'reverse_as' property metadata");
        }
    }
    else {
        #Carp::cluck("No metadata!");
    }

    return @joins;
}

1;
