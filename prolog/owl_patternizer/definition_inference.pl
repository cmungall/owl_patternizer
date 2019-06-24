/** <module> definition_inference

  induces logical definitions of form: C EquivalentTo <ClassExpression>
  from lexical and logical (subClassOf) axioms

  First all ancestor and ancestor expressions are found;
  e.g. for 'foo catabolism' this could include 'catabolism' and 'has_output(foo)'

  then it will test to see if the names for foo and catabolism are substrings of 'foo catabolism'
  
*/
:- module(definition_inference,
          [atom_class_token/4,
           parse_atom/3,
           best_parse_atom/4,
           best_parse_class/4,
           parse_tokens/3,

           % TODO: move
           save_axiom/1,
           save_axiom/2,
           infer_links/1,
           make_class_subterm_link/4,
           matches_to_class_expression/2,
           assert_inferred_equiv_axioms/0,           
           assert_inferred_equiv_axioms/1,           
           assert_inferred_equiv_axioms/2,           
           assert_inferred_equiv_axioms/3]).

:- use_module(library(owl_patternizer)).
:- use_module(library(rdf_matcher)).
:- use_module(library(sparqlprog/emulate_builtins)).
:- use_module(library(sparqlprog/owl_util)).
:- use_module(library(semweb/rdfs)).
:- use_module(library(semweb/rdf11)).
:- use_module(library(tabling)).
:- use_module(library(index_util)).

:- table class_prop_tokens/4.

:- rdf_register_prefix(inca, 'https://w3id.org/inca/').


%! class_prop_tokens(?Cls, ?AnnProp, ?OpenToks:list, ?Rest:list) is nondet
%
%    e.g. if a class has label 'foo of bar', then Toks = [foo,of,bar]
%    OpenToks = [foo,of,bar|Rest]
%
%  
class_prop_tokens(C,P,OpenToks,Rest) :-
        tr_annot(C,P,V,_,_,_),
        concat_atom(Toks,' ',V),
        append(Toks,Rest,OpenToks).

%! atom_class_token(+Atom, ?Cls, ?PreList:list, ?Rest:list) is nondet
%
%   named entity recognition on tokenization of Atom
%
%   true if Atom can be parsed as [PreList, labelOf(Cls), Rest];
%
atom_class_token(A,C,PreList,Rest) :-
        mutate(_,_,A,A2),
        concat_atom(Toks,' ',A2),
        append(PreList,SubList,Toks),
        class_prop_tokens(C,_P,SubList,Rest),
        \+ ((PreList=[], Rest=[])).

%! parse_atom(+Cls, +Atom, ?Matches:list) is nondet
%! parse_atom(+Cls, +Atom, ?Matches:list, ?Score) is nondet
%
%   parse Atom, ensure that matched entities are
%   (inferred or asserted) superclasses of Cls
% 
%   Matches = list of either class spans or tokens
%
%   Score is somewhat ad-hoc metric that rewards genus-differentia
%   style definitions (exactly 1 genus, 1 or more differentia)
%
parse_atom(C, A, Ms) :-
        % TODO: check if used
        mutate(_,_,A,A2),
        concat_atom(Toks,' ',A2),
        % if no score required, bulk of work done by parse_tokens/3
        parse_tokens(C, Toks, Ms),
        Ms=[_,_|_],
        \+ \+ member(span(_,_,_),Ms).

parse_atom(C, A, Ms, Score) :-
        debug(xdef,'Looking up BM for ~w ~w',[C, A]),
        atom_bm(A, BM, _),
        debug(xdef,'Parsing ~w atom = ~w',[C, A]),
                                % if score required, use this strategy
        recursive_parse_bm(C, BM, Ms, []),
        score_spans(Ms, Score).

% score a set of matches
score_spans(Ms, Score) :-
        findall(C,member(span(C,_,_),Ms), Cs),
        Cs=[_|_],
        length(Cs, NC),
        findall(Genus,member(span(Genus,Genus,_),Ms), Genuses),
        length(Genuses, NG),
        nc_ng_score(NC,NG,BaseScore),
        findall(W,member(word(W),Ms),Ws),
        length(Ws,NumWs),
        Score is BaseScore-NumWs.

% score based on total number of classes in signature and number of Genuses
nc_ng_score(0,_,0) :- !.
nc_ng_score(1,_,1) :- !.
nc_ng_score(_,0,4) :- !.
nc_ng_score(_,1,8) :- !.
nc_ng_score(_,_,6) :- !.

%! recursive_parse_bm(+MainCls, +BM:bitmap, ?Matches:list, +Visited:list) is nondet.
%
% BM is a bitmap representation of a name or syn of MainCls
% 
% will iteratively parse the string representation, subtracting out the matched portions
%
recursive_parse_bm(MainCls, BM, [Span|Ms], Vs) :-
        Match=match(_Score,ParentCls,Expr,P,IxnBM),
        setof(Match,
              bm_class_match(MainCls, BM, Match, Vs),
              Pairs),
        !,
        BMSize is popcount(BM),
        length(Pairs,NumPairs),
        debug(xdef,'|Pairs for ~w| = ~w // visited = ~w  // |BM|=~w',[MainCls,NumPairs,Vs,BMSize]),
        % take best match
        reverse(Pairs,[Match|_]),
        BM2 is BM - IxnBM,
        Span = span(Expr, ParentCls, P),
        debug(xdef,'  Span = ~w',[Span]),
        recursive_parse_bm(MainCls, BM2, Ms, [ParentCls|Vs]).
recursive_parse_bm(_MainCls, BM, Words, _) :-
        % no more matches from remaining BM
        bm_tokens(BM, Toks),
        findall(word(Tok),member(Tok,Toks),Words).
        
bm_class_match(MainCls, BM, Match, Vs) :-
        BM > 0,
        Match=match(Score,ParentCls,Expr,P,IxnBM),
        % get ancestor or ancestor expression
        % e.g if MainCls='foo biosynthesis', ParentCls=foo, Expr=some(has_output,foo)
        class_references(MainCls, ParentCls, Expr),
        \+ member(ParentCls, Vs),
        % bitmap of parentCls
        class_prop_bm(ParentCls,P,_V,ParentBM),
        P\=id,
        P\=uri,
        % intuitively, the parent name should be subsumed by the main class name
        ParentCls \= MainCls,
        IxnBM is BM /\ ParentBM,
        IxnBM > 0,
        LenIxn is popcount(IxnBM),
        LenPBM is popcount(ParentBM),
        % | MainCls /\ Parent| / | Parent |
        Score is LenIxn / LenPBM,
        %debug(def,' POSSIBLEMATCH(~w <=> ~w) = Score: ~w // p=~w // ~w' ,[MainCls, ParentCls, Score, P, _V]),
        Score > 0.66.
        
        
        
%! best_parse_atom(+Cls, +Atom, ?Ms:list, ?Score) is det
%
%   parse Atom, ensure that matched entities are
%   (inferred or asserted) superclasses of Cls
%
best_parse_atom(C, A, Ms, Score) :-
        debug(def,'Looking for best parse for ~w ~w',[C, A]),        
        aggregate(max(Score1,Ms1),parse_atom(C, A, Ms1, Score1),max(Score,Ms)).



%! parse_tokens(+MainClass, +Tokens:list, ?Matches:list) is nondet
%
%   parse a list of word tokens to a match list
%
%   all matched entities must be a superclass or superclass-expression of MainClass
%
%     Match = word(Token) | span(ClassExpression, Class, AnnotationProp)
%
:- table parse_tokens/3.

parse_tokens(_, [], []).
parse_tokens(MainClass, Tokens, [span(Expr,C,P)|Matches]) :-
        Tokens \= [],
        class_prop_tokens(C,P,Tokens,Rest),
        C\=MainClass,
        class_references(MainClass, C, Expr),
        parse_tokens(MainClass, Rest, Matches).
parse_tokens(MainClass, [T|Tokens], [word(T)|Matches]) :-
        parse_tokens(MainClass, Tokens, Matches).

:- table class_anylabel/3.
class_anylabel(C,P,V) :-
        tr_annot(C,P,V,_,_,_),
        P\=id,
        P\=uri.

%! parse_class(+Cls, ?Prop, ?Ms:list, ?Score) is nondet
%
%   parse the label or other annotations for Cls
%
parse_class(C, P, Ms, Score) :-
        debug(xdef,'parse_class: Looking for best parse for ~w',[C]),        
        %tr_annot(C,P,V,_,_,_),
        %P\=id,
                                %P\=uri,
        class_anylabel(C,P,V),
        debug(xdef,'  parse atom ~w ~w',[C, V]),        
        parse_atom(C,V,Ms,Score).

%! best_parse_class(+Cls, ?Prop, ?Ms:list, ?Score) is semidet
%
%    find best parse for Cls over parse_class/4
%
best_parse_class(C, P, Ms, Score) :-
        debug(def,'Looking for best parse for ~w ~w',[C, P]),        
        aggregate(max(Score1,P-Ms1),parse_class(C, P, Ms1, Score1),max(Score,P-Ms)).


%! matches_to_class_expression(+Matches:list, ?Expr:classExpression) is semidet
%
%    takes Matches (output of best_parse_class/4) and converts to an OWL class expression
%
%    this will be the conjunction (AND) of all expression spans
%
matches_to_class_expression(Ms, and(Xs)) :-
        setof(X,C1^P1^member(span(X,C1,P1),Ms),Xs),
        % at least two members
        Xs=[_,_|_].


% TODO: move these
save_axiom(Axiom) :-
        rdf_default_graph(G),
        save_axiom(Axiom,G).

save_axiom(Axiom,G) :-
        save_axiom(Axiom,_,G).
save_axiom(equivalentTo(A,B),rdf(A,owl:equivalentClass,B),G) :-
        !,
        debug(def, 'Saving ~w = ~w to ~w',[A,B,G]),
        save_expression(A,Ax,G),
        save_expression(B,Bx,G),
        rdf_assert(Ax,owl:equivalentClass,Bx,G).
save_axiom(subClassOf(A,B),rdf(A,rdfs:subClassOf,B),G) :-
        !,
        save_expression(A,Ax,G),
        save_expression(B,Bx,G),
        rdf_assert(Ax,rdfs:subClassOf,Bx,G).
save_axiom(T,T,G) :-
        T=rdf(S,P,O),
        !,
        rdf_assert(S,P,O,G).

save_axiom_with_anns(Axiom,G,Anns) :-
        save_axiom_with_anns(Axiom,_,G,Anns).
save_axiom_with_anns(Axiom,T,G,Anns) :-
        save_axiom(Axiom,T,G),
        T=rdf(S,P,O),
        save_expression(P,Px,G),
        save_expression(S,Sx,G),
        save_expression(O,Ox,G),
        rdf_create_bnode(AxiomNode),
        debug(def, 'Saving AxiomAnnotation ~w = ~w -> ~w // ~w,~w,~w',[AxiomNode,AP,V,S,Px,O]),
        rdf_assert(AxiomNode,owl:annotatedSource,Sx,G),
        rdf_assert(AxiomNode,owl:annotatedProperty,Px,G),
        rdf_assert(AxiomNode,owl:annotatedTarget,Ox,G),
        rdf_assert(AxiomNode,rdf:type,owl:'Axiom',G),
        forall(member(annotation(AP,V),Anns),
               rdf_assert(AxiomNode,AP,V,G)),
        !.
save_axiom_with_anns(Axiom,T,G,Anns) :-
        throw(error(could_not_save(Axiom,T,G,Anns))).



% TODO: axiom annotation
save_expression(and(Xs),Node,G) :-
        !,
        rdf_create_bnode(Node),
        debug(xdef,'Made IXN bnode: ~w',[Node]),
        rdf_assert(Node,rdf:type,owl:'Class',G),
        maplist({G}/[In,Out]>>save_expression(In,Out,G),Xs,IxnNodesPL),
        debug(xdef, 'AND list = ~w',[IxnNodesPL]),
        rdf_assert_list(IxnNodesPL,IxnNode,G),
        rdf_assert(Node,owl:intersectionOf,IxnNode,G).
save_expression(some(P,V),Node,G) :-
        !,
        rdf_create_bnode(Node),
        save_expression(P,Px,G),
        save_expression(V,Vx,G),
        rdf_assert(Node,rdf:type,owl:'Restriction',G),
        rdf_assert(Node,owl:onProperty,Px,G),
        rdf_assert(Node,owl:someValuesFrom,Vx,G).
save_expression(Node,Node,_) :-
        Node = _^^_,
        !.
save_expression(Node,Node,_) :-
        Node = _@_,
        !.
save_expression(P:X,Node,_) :-
        rdf_global_id(P:X,Node),
        !.
save_expression(Node,Node,_) :-
        atomic(Node),
        !.


%! assert_inferred_equiv_axioms is det
%
%   as assert_inferred_equiv_axioms/3, with default graph `gen`
%   and iterating over all classes
%
assert_inferred_equiv_axioms :-
        assert_inferred_equiv_axioms(_,gen,[]).

%! assert_inferred_equiv_axioms(+Opts:list) is det
%
%   as assert_inferred_equiv_axioms/3, with default graph `gen`
%   and iterating over all classes
%
assert_inferred_equiv_axioms( Opts) :-
        assert_inferred_equiv_axioms(_,gen,Opts).

%! assert_inferred_equiv_axioms(+Class:owlClass, +Graph) is det
assert_inferred_equiv_axioms(C,G) :-
        assert_inferred_equiv_axioms(C,G,[]).


%! assert_inferred_equiv_axioms(+Class:owlClass, +Graph, +Opts:list) is det
assert_inferred_equiv_axioms(C,G,Opts) :-
        forall((owl:class(C),
                \+ exclude_class(C,Opts),
                best_parse_class(C, P, Ms, Score),
                matches_to_class_expression(Ms, Expr),
                rdf_canonical_literal(Score,ScoreLiteral),
                atom_string(P,PStr),
                rdf_canonical_literal(PStr, PLit)),
               save_axiom_with_anns(equivalentTo(C,Expr),G,
                                    [annotation(inca:score,ScoreLiteral),
                                     annotation(inca:annotationPropertyUsed,PLit),
                                     annotation(rdfs:comment, "Autogenerated")])).
        

exclude_class(C,Opts) :- option(new_only(true),Opts), class_equiv_expression(C,_).
exclude_class(C,Opts) :-
        option(ontology_prefix(Prefix),Opts),
        \+ rdf_global_id(Prefix:_,C),
        \+ atom_concat(Prefix,_,C).
        
:- table class_references/3.
% e.g if MainCls='foo biosynthesis'
%   solution:  ParentCls=foo, Expr=some(has_output,foo)
%   solution:  ParentCls=metabolism, Expr=metabolism
class_references(C,P,X) :- rdfs_subclass_of(C,D), class_directly_references(D,P,X).
class_references(C,P,X) :- class_directly_references(C,P,X).

class_directly_references(C,C,C).
class_directly_references(C,P,some(Rel,P)) :- owl_some(C,Rel,P).

% non-tabled version
class_references_nt(C,P,X) :- rdfs_subclass_of(C,D), class_directly_references(D,P,X).
class_references_nt(C,P,X) :- class_directly_references(C,P,X).

%! class_subterm(?Cls, ?AnnProp, ?SubTerm:atom) is nondet
class_subterm(C,P,T) :-
        basic_annot(C,P,V,_),
        P=label, % TODO
        P\=id,
        P\=uri,
        concat_atom(Toks,' ',V),
        Toks=[_,_|_],
        append(_Pre,Rest,Toks),
        Rest\=[],
        append(Sub,_Post,Rest),
        Sub\=[],
        concat_atom(Sub,' ',T).

%! infer_links(+Opts:list) is det
%
%    infer basic subClassOf-someValuesFrom links based on lexical patterns
%
infer_links(Opts) :-
        % TODO: re-calc indexes
        materialize_index(basic_annot(+,+,-,-)),
        materialize_index(tr_annot(+,+,-,-,+,+)),
        make_class_subterm_link(_,_,sc,Opts),
        fail.
infer_links(_).

%! make_class_subterm_link(?Cls, ?RelCls, +Graph, +Opts:list) is det
make_class_subterm_link(C,C2,G,Opts) :-
        class_subterm(C,_,T),
        debug(def,'subterm of ~w = ~w',[C,T]),
        subterm_equiv(T,C2,G,Opts),
        \+ class_references_nt(C,C2,_),
        \+ class_references_nt(C2,C,_),
        debug(def,'making new link ~w REL ~w',[C,C2]),
        save_axiom(subClassOf(C,some(skos:related,C2)),G).

subterm_equiv(T,C,_,_Opts) :-
        tr_annot(C,label,T,_,_,_),
        !.
subterm_equiv(T,C,_,_Opts) :-
        tr_annot(C,_,T,_,_,_),
        !.
subterm_equiv(T,C,G,Opts) :-
        member(new_class_prefix(Prefix),Opts),
        debug(def,'making new class ~w~w',[Prefix,T]),
        !,
        concat_atom([Prefix,T],C),
        rdf_assert(C,rdf:type,owl:'Class',G),
        rdf_canonical_literal(T,Lit),
        rdf_assert(C,rdfs:label,Lit,G).



        

        
