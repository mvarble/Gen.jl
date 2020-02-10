import MacroTools

is_primitive(::Function) = false
check_is_kernel(::Function) = false

function check_observations(choices::ChoiceMap, observations::ChoiceMap)
    for (key, value) in get_values_shallow(observations)
        !has_value(choices, key) && error("Check failed: observed choice at $key not found")
        choices[key] != value && error("Check failed: value of observed choice at $key changed")
    end
    for (key, submap) in get_submaps_shallow(observations)
        check_observations(get_submap(choices, key), submap)
    end
end

macro pkern(ex)
    MacroTools.@capture(ex, function f_(args__) body_ end) || error("expected a function")
    quote
        function $(esc(f))($(args...), check = false, observations = EmptyChoiceMap())
            trace::Trace = $body
            check && check_observations(get_choices(trace), observations)
            trace
        end
        is_primitive($(esc(f))) = true
        check_is_kernel($(esc(f))) = true
    end
end

function expand_kern_ex(ex)
    MacroTools.@capture(ex, function f_(args__) body_ end) || error("expected a function")

    ex = quote
        function $(esc(f))(trace::Trace, $(args...), check = false, observations = EmptyChoiceMap())
            $body
            check && check_observations(get_choices(trace), observations)
            trace
        end
        check_is_kernel($(esc(f))) = true
    end

    # replace @tr() with trace
    ex = MacroTools.postwalk(ex) do x
        MacroTools.@capture(x, @tr()) ? :trace : x
    end

    # for loops
    ex = MacroTools.postwalk(ex) do x
        MacroTools.@capture(x, for idx_ in range_ body_ end) || return x
        quote
            loop_range = $range
            for $idx in loop_range
                $body
            end
            check && (loop_range != $range) && error("Check failed in loop")
        end
    end

    # if .. end
    ex = MacroTools.postwalk(ex) do x
        MacroTools.@capture(x, if cond_ body_ end) || return x
        quote
            cond = $cond
            if cond
                $body
            end
            check && (cond != $cond) && error("Check failed in if-end")
        end
    end

    # let
    ex = MacroTools.postwalk(ex) do x
        MacroTools.@capture(x, let var_ = rhs_; body_ end) || return x
        quote
            rhs = $rhs
            let $var = rhs
                $body
            end
            check && (rhs != $rhs) && error("Check failed in let")
        end
    end

    # mixture
    ex = MacroTools.postwalk(ex) do x
        MacroTools.@capture(x, let idx_ ~ dist_(args__); body_ end) || return x
        quote
            dist = $dist
            args = ($(args...),)
            let $idx = dist($(args...))
                $body
            end
            check && (dist != $dist) && error("Check failed in mixture (distribution)")
            check && (args != ($(args...),)) && error("Check failed in mixture (arguments)")
        end
    end

    # applying a kernel
    ex = MacroTools.postwalk(ex) do x
        MacroTools.@capture(x, @app K_(args__)) || return x
        quote
            check && check_is_kernel($(esc(K)))
            trace = $(esc(K))(trace, $(args...), check)
        end
    end

    ex, f
end

function reversal(f)
    check_is_kernel(f)
    error("Reversal for kernel $f is not defined")
end

macro revkern(ex)
    MacroTools.@capture(ex, k_ : l_) || error("expected a pair of functions")
    quote
        is_primitive($k) || error("first function is not a primitive kernel")
        is_primitive($l) || error("second function is not a primitive kernel")
        reversal($k) = $l
        reversal($l) = $k
    end
end


function reversal_ex(ex)

    MacroTools.@capture(ex, function f_(args__) body_ end) || error("expected a function")

    # change the name
    ex = quote
        function rev($(args...))
            $body
        end
    end

    # for loops
    ex = MacroTools.postwalk(ex) do x
        MacroTools.@capture(x, for idx_ in range_ body_ end) || return x
        quote
            for $idx in reverse(loop_range)
                $body
            end
        end
    end

    # applying a kernel
    ex = MacroTools.postwalk(ex) do x
        MacroTools.@capture(x, @app K_(args__)) || return x
        quote
            @app_ reversal($K)($(args...))
        end
    end
    ex = MacroTools.postwalk(ex) do x
        MacroTools.@capture(x, @app_ K_(args__)) || return x
        quote
            @app $K($(args...))
        end
    end


    ex
end

macro kern(ex)
    kern_ex, kern = expand_kern_ex(ex)
    rev_kern_ex, rev_kern = expand_kern_ex(reversal_ex(ex))
    quote
        # define forward kerel
        $kern_ex
        
        # define reversal kernel
        $rev_kern_ex

        # bind the reversals for both
        Gen.reversal($(esc(kern))) = $rev_kern
        Gen.reversal($rev_kern) = $(esc(kern))
    end
end

export @pkern, @revkern, @kern, reversal
