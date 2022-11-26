-module(ssl_cth).
-include("ssl_test_lib.hrl").
-export([init/2]).
-export([pre_init_per_suite/3, post_init_per_suite/4]).
-export([pre_end_per_suite/3, post_end_per_suite/4]).
-export([pre_init_per_group/4, post_init_per_group/5]).
-export([pre_end_per_group/4, post_end_per_group/5]).
-export([pre_init_per_testcase/4, post_init_per_testcase/5]).
-export([pre_end_per_testcase/4, post_end_per_testcase/5]).
-export([on_tc_fail/4, on_tc_skip/4, terminate/1]).
-record(state,
        {
         file_handle,
         suite_passed,
         suite_failed,
         suite_skipped,
         total_passed = 0,
         total_failed = 0,
         total_skipped = 0,
         suite_ts,
         start_ts,
         data,
         trace
        }).
-define(MAYBE_TRACE(Instruction, Trace),
        begin
            case Trace of
                true ->
                    Instruction;
                _ -> ok
            end
        end).
-define(TRACE_ENTER(Fmt, A, B, Trace),
        ?MAYBE_TRACE(
           ssl_trace:write("----> " ++ Fmt ++ " ~w ---->~n",
                           [A, B, ?FUNCTION_NAME]), Trace)).
-define(TRACE_LEAVE(Fmt, A, B, Trace),
        ?MAYBE_TRACE(
           ssl_trace:write("<---- " ++ Fmt ++ " ~w <----~n",
                           [A, B, ?FUNCTION_NAME]), Trace)).

init(_Id, _Opts) ->
    ResultsFolder = os:getenv("CT_RESULTS_FOLDER"),
    Trace = os:getenv("TRACE"),
    ?PAL("TRACE = ~s CT_RESULTS_FOLDER = ~s", [Trace, ResultsFolder]),
    Commit = os:cmd("git rev-parse --short HEAD | tr -d '\n'"),
    Dir = case ResultsFolder of
              false -> "/tmp/";
              _ -> ResultsFolder
          end,
    File = Dir ++ "ct_results_" ++ Commit ++ ".txt",
    ?PAL("CT results file = ~s", [File]),
    SymLink = Dir ++ "latest.log",
    file:delete(SymLink),
    ok = file:make_symlink(File, SymLink),
    {ok,D} = file:open(File,[write]),
    io:format(D, "~s~n", [File]),
    {ok, #state{
            file_handle = D,
            data = [],
            start_ts = erlang:system_time(second),
            trace = ("true" == Trace)}}.
%
pre_init_per_suite(Suite,Config,#state{trace=Trace}=State) ->
    ?MAYBE_TRACE(
       begin
           ssl_trace:start(fun io:format/2, [file]),
           ssl_trace:on()
       end, Trace),
    ?TRACE_ENTER("~w~s", Suite, "", Trace),
    {Config, State#state{
               suite_ts = erlang:system_time(second)}}.
post_init_per_suite(Suite,_Config,Return,#state{trace=Trace}=State) ->
    ?TRACE_LEAVE("~w~s", Suite, "", Trace),
    io:format(State#state.file_handle, "~n~w|",
               [Suite]),
    {Return, State#state{suite_passed = 0, suite_failed = 0, suite_skipped = 0}}.
pre_end_per_suite(Suite,Config,#state{trace=Trace}=State) ->
    ?TRACE_ENTER("~w~s", Suite, "", Trace),
    {Config, State}.
post_end_per_suite(Suite,_Config,Return,#state{trace=Trace}=State0) ->
    ?TRACE_LEAVE("~w~s", Suite, "", Trace),
    State = State0#state{
              total_passed = State0#state.total_passed +
                  State0#state.suite_passed,
              total_failed = State0#state.total_failed +
                  State0#state.suite_failed,
              total_skipped = State0#state.total_skipped +
                  State0#state.suite_skipped},
    SuiteTime = erlang:system_time(second) - State0#state.suite_ts,
    TotalTime = erlang:system_time(second) - State0#state.start_ts,
    io:format(State#state.file_handle, "|~w. ~wS ~wX (~w. ~wS ~wX)|" ++
                  get_nice_time(SuiteTime) ++
                  " (" ++ get_nice_time(TotalTime) ++ ")",
              [State#state.suite_passed, State#state.suite_skipped,
               State#state.suite_failed, State#state.total_passed,
               State#state.total_skipped, State#state.total_failed]),
    ssl_trace:stop(),
    {Return, State}.

pre_init_per_group(Suite,Group,Config,#state{trace=Trace}=State) ->
    ?TRACE_ENTER("~w@~w", Suite, Group, Trace),
    {Config, State}.
post_init_per_group(Suite,Group,_Config,Return,#state{trace=Trace}=State) ->
    ?TRACE_LEAVE("~w@~w", Suite, Group, Trace),
    {Return, State}.
pre_end_per_group(Suite,Group,Config,#state{trace=Trace}=State) ->
    ?TRACE_ENTER("~w@~w", Suite, Group, Trace),
    {Config, State}.
post_end_per_group(Suite,Group,_Config,Return,#state{trace=Trace}=State) ->
    ?TRACE_LEAVE("~w@~w", Suite, Group, Trace),
    {Return, State}.
pre_init_per_testcase(Suite,TC,Config,#state{trace=Trace}=State) ->
    ?TRACE_ENTER("~w:~w", Suite, TC, Trace),
    {Config, State}.
post_init_per_testcase(Suite,TC,_Config,Return,#state{trace=Trace}=State) ->
    ?TRACE_LEAVE("~w:~w", Suite, TC, Trace),
    {Return, State}.
pre_end_per_testcase(Suite,TC,Config,#state{trace=Trace}=State) ->
    ?TRACE_ENTER("~w:~w", Suite, TC, Trace),
    {Config, State}.
post_end_per_testcase(Suite,TC,_Config,Return,#state{trace=Trace}=State0) ->
    ?TRACE_LEAVE("~w:~w", Suite, TC, Trace),
    {R, State} =
       case Return of
           ok ->
               {".",
                State0#state{suite_passed = State0#state.suite_passed + 1}};
           {skip, _} ->
               {io_lib:format("S", []),
                State0#state{suite_skipped = State0#state.suite_skipped + 1}};
           _ ->
               {io_lib:format("X", []),
                State0#state{suite_failed = State0#state.suite_failed + 1}}
       end,
   io:format(State0#state.file_handle, "~s",
             [R]),
   {Return, State}.

on_tc_fail(_Suite, _TC, _Reason, State) ->
    io:format(State#state.file_handle, "&", []),
    State.

on_tc_skip(_Suite, _TC, _Reason, State) ->
    io:format(State#state.file_handle, "^", []),
    State.

terminate(State) ->
    file:close(State#state.file_handle),
    ok.

get_nice_time(Seconds) ->
    case Seconds < 60 of
        true ->
            io_lib:format("~ws", [Seconds]);
        _ ->
            io_lib:format("~wm", [round(Seconds/60)])
          end.
