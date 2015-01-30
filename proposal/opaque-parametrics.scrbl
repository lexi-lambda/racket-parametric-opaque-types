#lang scribble/manual

@(require (for-label typed/racket/base
                     racket/contract/parametric
                     json
                     lang/posn
                     2htdp/image)
          racket/sandbox
          scribble/eval)

@(define (interaction-evaluator language)
   (parameterize ([sandbox-output 'string]
                  [sandbox-error-output 'string])
     (make-evaluator language)))

@title{Proposal: Generating Contacts for Parametric Opaque Types}

@section{Current contract behavior for parametric, non-opaque types}

Currently, Typed Racket makes relatively weak guarantees when using parametric structural types from
untyped code. This is unfortunately necessary since parametricity really only exists as a static
construct. Without instantiating the types, contracts cannot be made. This allows programs like the
following to successfully run.

@(define ex1-evaluator (interaction-evaluator 'racket/base))

@(interaction
  #:eval ex1-evaluator
  (module typed typed/racket/base
    (provide (struct-out Foo))
    (struct [A] Foo ([x : A] [y : A]) #:transparent))
  
  (require 'typed)
  (Foo "a" 'b))

Obviously, it would be impossible to know that @racket["a"] and @racket['b] are of different types
because the concept of "types" does not exist at runtime. However, the following program demonstrates
how Typed Racket prevents this lack of knowledge from "infecting" the typed code.

@(interaction
  #:eval ex1-evaluator
  (module typed-concat typed/racket/base
    (require 'typed)
    (provide foo-concat)
    (define (foo-concat [foo : (Foo String)]) : String
      (string-append (Foo-x foo) (Foo-y foo))))
  (require 'typed-concat)
  (foo-concat (Foo "a" 'b)))

This demonstrates that parametric structure types are something of a derived concept in Typed Racket,
despite being technically only being possible due to the @racket[struct] special form. Importantly,
the fact that @racket[Foo] is parametric does not cause any additional contracts to be generated since
@racket[A] is directly used as a field type. Contracts are only created at the @italic{point of
instantiation}.

@section{Extending parametricity to opaque types}

If parameterized types are a wholly static concept, they should, in theory, be able to be extended to
opaque types. As an example, consider the @racket[posn] structure from @racketmodname[lang/posn]. This
structure contains two fields of any type, but @racketmodname[2htdp/image] provides
@racket[real-valued-posn?] as a predicate for use in contracts. Ideally, we would be able to express
this in Typed Racket as a parameterized type.

A naïve attempt to use such a type in typed code might look something like this:

@#reader scribble/comment-reader
(racketblock
  ; make Posn parametric
  (define-type Posn (All (A) htdp:posn))
  
  (provide Posn)
  
  (require/typed
   lang/posn
   [#:opaque htdp:posn posn?])
  
  (require/typed/provide
   lang/posn
   [make-posn (All (A) A A -> (Posn A))]
   [posn-x (All (A) (Posn A) -> A)]
   [posn-y (All (A) (Posn A) -> A)]))

Sadly, this fails. Typed Racket attempts to apply a @racket[parametric->/c] contract to the various
@racket[posn] functions, and the values are wrapped. The wrapping and unwrapping functions are not
shared between functions, so attempting to retrieve values from @racket[posn] instances raises
contract errors. Furthermore, even if the wrappers @italic{were} shared between functions, untyped
code would recieved wrapped values, which would render them quite useless.

However, as mentioned above, all of the contract checking on these functions can be done from the
@italic{typed} side at runtime. Typed Racket just needs some information about how to correctly
generate contracts on opaque types.

@subsection{Creating an idealized syntax for describing parametric opaque imports}

The rest of the code in this document will be somewhat hypothetical and demonstrative. In order to
demonstrate the way the system @italic{should} work, there needs to be some basic syntax that can
express the required ideas. The issues of implemented such forms is a problem not addressed by this
document, but it is assumed to be trivial in comparison to the other problems laid out.

The proposed syntax to instruct Typed Racket to formulate a parametric type is as follows:

@(racketblock
  (require/typed
   [#:opaque (Posn A) posn?]
   [make-posn (All [A] A A -> (Posn A))]
   [posn-x (All [A] (Posn A) -> A A)]
   [posn-y (All [A] (Posn A) -> A A)]))

There are some important notes about this syntax.

@(itemlist
  @item{The actual important part occurs within the @racket[#:opaque] declaration. This declares
        @racket[Posn] as a @deftech{parametric opaque type}. This will need to be something of a
        first-class member of Typed Racket's type system, just as much as structure types are.}
  @item{In the various function declarations, the type of @racket[A] is inferred from the arguments,
        just as in any other parametric type declaration. No wrapping or unwrapping is needed via
        @racket[parametric->/c]. This guarantee is important! As mentioned earlier, any wrapping or
        unwrapping required by these functions will break interoperability with untyped Racket.})

@subsection{Using parametric opaque types in typed code}

Just as with parametric structure types, @tech{parametric opaque types} can be handled purely by the
static typechecker as long as they stay in typed code. Of course, the major difference is that
parametric opaque types must interact with untyped code @italic{by definition}, since they are opaque.
Even trickier, we cannot generate contracts as simply as we did with our @racket[Foo] structure and
the @racket[foo-concat] function that used its instantiation. Why? Consider the following code.

@(racketblock
  (: posn-2x ((Posn Real) -> Real))
  (define (posn-2x p)
    (* 2 (posn-x p)))
  
  (posn-2x (make-posn 2 4)))

This should work! But what if our untyped code misbehaves? What if, instead of getting
@racket[(posn 2 4)] from @racket[make-posn], the untyped code returns @racket[(posn 2 'error)]? This
is surprisingly problematic because, in @racket[posn-2x], there is @italic{no way for Typed Racket to
validate the provided value at runtime!} Since @racket[posn-y] is never used, as far as Typed Racket
knows, everything is going just fine. And that's actually okay. The types aren't broken because
@racket[posn-x] is correct. Ideally, we'd get a contract failure, but technically nothing has gone
wrong here.

But what about the other case? What if the returned value is completely bogus? What if
@racket[make-posn] yields @racket[(posn #f #f)]? Now we need to produce some kind of contract failure.
Obviously, the call to @racket[posn-x] in the typed code should be protected with a contract ensuring
that the return value is a @racket[Real]. That's not too hard—problem solved!

Unfortunately, it's unclear exactly @italic{how} the contract should be attached to @racket[posn-x].
It can't be attached in @racket[require/typed] because the contract depends entirely on the type
instantiation. Indeed, the contract needs to be attached in an on-demand basis. Typed Racket needs to
infer that the call to @racket[posn-x] is being applied with @racket[Real] as the concrete type, and
it needs to produce a chaperoned function in place of @racket[posn-x] that will ensure its return type
satisfies @racket[real?].

The precise mechanism by which the typechecker would be able to handle such a situation is unknown to
me. The best approach would probably hinge on ensuring optimal performance. Either way, it seems that
such a solution is well within the range of Typed Racket's operational functionality.

@subsection{Using parametric opaque types with untyped code}

This area is something I haven't given a huge amount of thought to, though it @italic{is} relevant:
what should the behavior be when exporting identifiers that interact with @tech{parametric opaque
types}, especially when imported into untyped modules? For the most part, the behavior described for
interactions in typed code seem to generalize to untyped code, maintaining the parallel between
parametric structure types and parametric opaque types.

Just like in the original example given using a parametric structure type, it would be impossible to
enforce such constraints in untyped code without type instantiation, similar to the equivalent problem
from the typed side of things.

@section{A request for feedback and proposal to implement parametric opaque types}

At this point, I will take the opportunity to speak for myself and admit that I am not terribly
familiar with how Typed Racket's typechecker and type environment work on the inside. I am certainly
willing to attempt to implement something like this myself, but seeing as this is all quite
hypothetical from my perspective, it would help to get the opinions of those more familiar with how
these things are implemented.

I @italic{do} believe that the implementation of such a system has the possibility of permitting the
use of various untyped idioms in typed code. Besides HtDP's @racket[posn] type, the @racket[jsexpr?]
type from the JSON library comes to mind with its support for custom nulls. This is an immediate
application of such a feature, and I could see it being made useful in other areas as well.

I would appreciate any comments on this proposal as well as any aid anyone is willing to give me to
assist in my eventual implementation of parametricity for opaque types. Please do not hesitate to
critique or make suggestions, as this is still a very simple draft, and I recognize that it might need
some major changes before being viable.
