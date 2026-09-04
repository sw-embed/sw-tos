# PL/SW feature requests from SWTOS

Things SWTOS wants from [sw-cor24-plsw](https://github.com/sw-embed/sw-cor24-plsw),
each with the evidence that produced it. Nothing here is a workaround request:
SWTOS builds today without any of it. They are places where the language costs
this codebase more than it needs to.

Reproduce anything below from a clean SWTOS tree with `just scheduled-shell-build`.

---

## 1. `%IF DEFINED(...)` inside macro source-template bodies

**Want:** gate a statement in a `MACRODEF` body on whether an OPTIONAL clause
was supplied, at compile time.

**Why.** SWTOS prints strings constantly, in two shapes: a string, and a string
followed by a newline. Written as one macro with a switch, the natural surface
is

```plsw
?PRINT TEXT(SHELL_KILL_USAGE) NL(TRUE);
```

but the body can only be

```
CALL UART_PUTS(ADDR({TEXT}));
IF ({NL} = 1) THEN CALL UART_PUTCHAR(10);
```

which is a **runtime** test. Every call site pays a compare and a branch to
decide something the compiler knew, and the expansion is no longer identical to
the hand-written call it replaces -- which is the property that makes the
refactor provable (see below). So SWTOS ships two macros, `?PRINT` and
`?PRINTLN`, and a comment explaining why they are not one.

With compile-time gating the body would be

```
CALL UART_PUTS(ADDR({TEXT}));
%IF DEFINED(NL); CALL UART_PUTCHAR(10); %ENDIF;
```

and the two macros collapse into one with no cost at any call site.

### The same feature, needed a second time: pointer or named string

`UART_PUTS` takes one pointer to NUL-terminated bytes, and callers arrive at
that pointer three ways:

```plsw
CALL UART_PUTS(ADDR(SHELL_BAD_TEXT));   /* a declared array: take its address */
CALL UART_PUTS(TEXT_PTR);               /* a PTR parameter: already an address */
CALL UART_PUTS(DESC_PTR->SPD_NAME);     /* a field in a based record */
```

A clause declared `TEXT(lvalue)` and wrapped by the body in `ADDR({TEXT})`
serves the first and silently breaks the others: `ADDR(TEXT_PTR)` is the
address *of the pointer*, so it compiles and prints whatever those bytes
happen to be. A clause declared `AT(expr)` and used bare serves all three.
SWTOS confirmed this by compiling each shape:

| invocation | compiles |
|---|---|
| `?PRINTLN AT(TEXT_PTR);` | yes |
| `?PRINTLN AT(DESC_PTR->SPD_NAME);` | yes |
| `?PRINTLN AT(ADDR(SHELL_BAD_TEXT));` | yes |

But `AT` alone is the wrong default: 53 call sites here name a string and 2
hold a pointer, so unifying on `AT` would make the common case carry a visible
`ADDR()` to spare the rare one. What is wanted is one macro accepting either
clause:

```
MACRODEF PRINTLN;
    OPTIONAL TEXT(lvalue);
    OPTIONAL AT(expr);
    %IF DEFINED(TEXT); CALL UART_PUTS(ADDR({TEXT})); %ENDIF;
    %IF DEFINED(AT);   CALL UART_PUTS({AT});         %ENDIF;
    CALL UART_PUTCHAR(10);
END;
```

which is the same missing feature as the newline switch above. With it, one
macro with three optional clauses replaces `?PRINT`, `?PRINTLN` and both
argument shapes. Without it each combination needs its own name, and SWTOS
leaves the pointer callers as plain `CALL UART_PUTS`.

**A smaller diagnostic that would help either way.** `ADDR()` applied to
something that is already an address is always a bug, and today it is a silent
one that prints garbage. A warning when `ADDR()` is applied to a `PTR` would
catch this class of mistake where it is made, whether or not clause gating
lands.

**Already known.** `docs/storage-allocation.md` in the compiler repo says the
same thing about `?GETMAIN`:

> `RC` is **required** in v1. PL/SW's macro system doesn't yet support
> `%IF DEFINED(RC)` inside source-template bodies, which is what an OPTIONAL
> clause would need to gate its emission.

So this request is that note, seconded twice: once for a newline switch, once
for accepting either an lvalue or an address expression. Three callers, one
feature.

**Scope note.** `%IF` already exists for conditional compilation at file scope.
What is missing is availability *inside* a template body, evaluated against the
clauses actually supplied at the invocation being expanded.

---

## 2. Source-line attribution stops at line 256

**Bug, not a feature.** The compiler emits each source statement as a comment
above the instructions it generated:

```
; 13:     CALL UART_PUTCHAR(10);
        lc      r0,10
```

Those comments are what make SWTOS's debugger useful on a PL/SW program: `list`
reads the generated assembly, so it shows the PL/SW that was written rather
than only the assembly it became.

**It stops at 256.** In `build/scheduled-shell/app.s`, the highest lines named
are `251, 252, 253, 254, 255, 256` -- and then nothing, in that file or any
other generated file in the tree. The compiler's input here is a concatenated
stream of 30 lines of generated catalog plus 1,229 lines of
`tests/catalog-shell.plsw`, so attribution covers the first 20% of the program
and stops.

`256` is `255 + 1`, which is what a byte holding `line - 1` can represent. That
is a guess at the cause; the ceiling itself is measured.

Reproduce:

```sh
just scheduled-shell-build
grep -rhoE '^; [0-9]+:' build/*/[a-z]*.s | sort -t' ' -k2 -n | tail -1
```

**Want:** a counter wide enough for the file, and ideally the source *name*
alongside the line, since a build concatenates several PL/SW inputs into one
stream and a stream line number is not a line number in any file a person has
open.

## 3. Macro invocation syntax is documented two ways, and one does not parse

`docs/usage.md` shows

```plsw
?LED_SET(VAL(1));      /* outer parens */
?GREET(MSG(_MSG));
```

`docs/storage-allocation.md` shows

```plsw
?GETMAIN SET(P) LENGTH(12) RC(rc);   /* no outer parens */
```

Only the second parses. The first fails with

```
SYNTAX ERROR line N: macro invocation failed
  expected END, got (
```

**Want:** either accept both, or correct `usage.md` and the `greet.msw` /
`hello_macro.plsw` examples. The examples are where a new caller looks first,
and they are the form that does not work.

---

## What SWTOS proved while finding these

Source-emission macros expand to **byte-identical instructions**. Adding
`?PRINT` and `?PRINTLN` and converting call sites left all 5,515 lines of
generated assembly unchanged except the `; N:` comments, which shifted by the
number of lines the definitions added:

```sh
grep -v '^; [0-9]*:' before.s > b.code
grep -v '^; [0-9]*:' build/scheduled-shell/app.s > a.code
diff b.code a.code        # empty
```

That is the property worth protecting in any change to the expansion machinery,
and it is what makes a large mechanical refactor of PL/SW source safe to do:
the compiler can prove the result is the same program.

`REQUIRED AT(expr)` was separately confirmed to accept a bare pointer, a
based-record field dereference, and a wrapped `ADDR()`. Textual substitution
followed by a re-parse means a clause takes whatever PL/SW would have accepted
written by hand, which is worth stating because it bounds how much a clause
type needs to constrain.

`docs/cs-macro.md` in the compiler repo (§7) explains why this works without a
gensym: source-template bodies take their branch labels from the compiler's
global `emit_label_next` counter, so any number of invocations are
collision-free. Only `GEN DO` templates with symbolic labels have the
duplicate-symbol hazard.
