%%
%% %CopyrightBegin%
%%
%% Copyright Ericsson AB 2008-2024. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% %CopyrightEnd%
%%

%%

-module(ssh_acceptor).
-moduledoc false.

-include("ssh.hrl").
-include_lib("/home/ejakwit/src/tools/src/tools.hrl").

%% Internal application API
-export([start_link/3,
	 number_of_connections/1]).

%% spawn export
-export([acceptor_init/4, acceptor_loop/6]).

-behaviour(ssh_dbg).
-export([ssh_dbg_trace_points/0, ssh_dbg_flags/1, ssh_dbg_on/1, ssh_dbg_off/1,
         ssh_dbg_format/2, ssh_dbg_format/3]).

-define(SLEEP_TIME, 200).

%%====================================================================
%% Internal application API
%%====================================================================
%% Supposed to be called in a child-spec of the ssh_acceptor_sup
start_link(SystemSup, Address, Options) ->
    proc_lib:start_link(?MODULE, acceptor_init, [self(),SystemSup,Address,Options]).


accept(ListenSocket, AcceptTimeout, Options) ->
    {_, Callback, _} = ?GET_OPT(transport, Options),
    Callback:accept(ListenSocket, AcceptTimeout).

close(Socket, Options) ->
    {_, Callback, _} = ?GET_OPT(transport, Options),
    Callback:close(Socket).

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
acceptor_init(AcceptorSup, SystemSup,
              #address{address=Address, port=Port, profile=_Profile},
              Opts) ->
    ssh_lib:set_label(server,
                      {acceptor,
                       list_to_binary(ssh_lib:format_address_port(Address, Port))}),
    AcceptTimeout = ?GET_INTERNAL_OPT(timeout, Opts, ?DEFAULT_TIMEOUT),
    {LSock, _LHost, _LPort, _SockOwner} =
        ?GET_INTERNAL_OPT(lsocket, Opts, undefined),
    proc_lib:init_ack(AcceptorSup, {ok, self()}),
    acceptor_loop(Port, Address, Opts, LSock, AcceptTimeout,
                  {SystemSup, AcceptorSup}).

%%%----------------------------------------------------------------
acceptor_loop(Port, Address, Opts, ListenSocket, AcceptTimeout, Sups) ->
    ?DBG_TERM(?GET_OPT(parallel_login, Opts)),
    try
        case accept(ListenSocket, AcceptTimeout, Opts) of
            {ok,Socket} ->
                PeerName = inet:peername(Socket),
                ParallelLogin = ?GET_OPT(parallel_login, Opts),
                MaxSessions = ?GET_OPT(max_sessions, Opts),
                {NumSessions, AcceptorCnt} = number_of_connections(Sups),
                ok = maybe_add_acceptor(ParallelLogin, AcceptorCnt),
                case handle_connection(Address, Port, PeerName, Opts, Socket,
                                       MaxSessions, NumSessions, ParallelLogin) of
                    {error,Error} ->
                        catch close(Socket, Opts),
                        handle_error(Error, Address, Port, PeerName);
                    _ ->
                        ok
                end;
            {error,Error} ->
                handle_error(Error, Address, Port, undefined)
        end
    catch
        Class:Err:Stack ->
            handle_error({error, {unhandled,Class,Err,Stack}}, Address, Port,
                         undefined)
    end,
    ?MODULE:acceptor_loop(Port, Address, Opts, ListenSocket, AcceptTimeout, Sups).

%%%----------------------------------------------------------------
handle_connection(_Address, _Port, _Peer, _Options, _Socket,
                  MaxSessions, NumSessions, _ParallelLogin)
  when NumSessions >= MaxSessions->
    {error,{max_sessions,MaxSessions}};
handle_connection(_Address, _Port, {error,Error}, _Options, _Socket,
                  _MaxSessions, _NumSessions, _ParallelLogin) ->
    {error,Error};
handle_connection(Address, Port, _Peer, Options, Socket,
                  _MaxSessions, _NumSessions, ParallelLogin)
  when ParallelLogin == false ->
    handle_connection(Address, Port, Options, Socket);
%% FIXME clause below is to be deleted, replaced with maybe_add_acceptor/2 functionality
handle_connection(Address, Port, _Peer, Options, Socket,
                  _MaxSessions, _NumSessions, ParallelLogin)
  when ParallelLogin == true ->
    Ref = make_ref(),
    Pid = spawn_link(
            fun() ->
                    process_flag(trap_exit, true),
                    receive
                        {start,Ref} ->
                            handle_connection(Address, Port, Options, Socket)
                    after 10000 ->
                            {error, timeout2}
                    end
            end),
    catch gen_tcp:controlling_process(Socket, Pid),
    Pid ! {start,Ref},
    ok.

handle_connection(Address, Port, Options0, Socket) ->
    Options = ?PUT_INTERNAL_OPT([{user_pid, self()}
                                ], Options0),
    ssh_system_sup:start_connection(server,
                                   #address{address = Address,
                                            port = Port,
                                            profile = ?GET_OPT(profile,Options)
                                           },
                                   Socket,
                                   Options).

%%%----------------------------------------------------------------
handle_error(Reason, ToAddress, ToPort, {ok, {FromIP,FromPort}}) ->
    handle_error(Reason, ToAddress, ToPort, FromIP, FromPort);

handle_error(Reason, ToAddress, ToPort, _) ->
    handle_error(Reason, ToAddress, ToPort, undefined, undefined).


handle_error(Reason, ToAddress, ToPort, FromAddress, FromPort) ->
    case Reason of
        {max_sessions, MaxSessions} ->
            error_logger:info_report(
              lists:concat(["Ssh login attempt to ",ssh_lib:format_address_port(ToAddress,ToPort),
                            " from ",ssh_lib:format_address_port(FromAddress,FromPort),
                            " denied due to option max_sessions limits to ",
                            MaxSessions, " sessions."
                           ])
             );

        Limit when Limit==enfile ; Limit==emfile ->
            %% Out of sockets...
            error_logger:info_report([atom_to_list(Limit),": out of accept sockets on ",
                                      ssh_lib:format_address_port(ToAddress, ToPort),
                                      " - retrying"]),
            timer:sleep(?SLEEP_TIME);

        closed ->
            error_logger:info_report(["The ssh accept socket on ",ssh_lib:format_address_port(ToAddress,ToPort),
                                      "was closed by a third party."]
                                    );

        timeout ->
            ok;

        Error when is_list(Error) ->
            ok;
        Error when FromAddress=/=undefined,
                   FromPort=/=undefined ->
            error_logger:info_report(["Accept failed on ",ssh_lib:format_address_port(ToAddress,ToPort),
                                      " for connect from ",ssh_lib:format_address_port(FromAddress,FromPort),
                                      io_lib:format(": ~p", [Error])]);
        Error ->
            error_logger:info_report(["Accept failed on ",ssh_lib:format_address_port(ToAddress,ToPort),
                                      io_lib:format(": ~p", [Error])])
    end.

%% FIXME add testcase for integer ParallelLogin
maybe_add_acceptor(ParallelLogin, AcceptorCnt)
  when is_integer(ParallelLogin), AcceptorCnt < ParallelLogin ->
    %% FIXME add permanent acceptor to the pool
    %% FIXME should they be permanent or should an integer budget should be specfied?
    ok;
maybe_add_acceptor(true, _) ->
    %% FIXME add volatile acceptor to the pool
    %% FIXME discuss - should we have a limit here as in SSH? MaxStartups
    ok;
maybe_add_acceptor(_, _) ->
    ok.

-define(SEARCH_FUN(Sup, Type, Module),
        fun() ->
                lists:foldl(
                  fun({_Ref, _Pid, Type, [Module]}, N) -> N+1;
                     (_, N) -> N
                  end, 0, supervisor:which_children(Sup))
        end()).
%%%----------------------------------------------------------------
number_of_connections({SysSupPid, AcceptorSupPid}) ->
    NumSessions = ?SEARCH_FUN(SysSupPid, supervisor, ssh_connection_sup),
    AcceptorCnt = ?SEARCH_FUN(AcceptorSupPid, worker, ssh_acceptor),
    %% ?DBG_TERM(supervisor:which_children(AcceptorSupPid)),
    ?DBG_TERM({NumSessions, AcceptorCnt}),
    {NumSessions, AcceptorCnt}.

%%%################################################################
%%%#
%%%# Tracing
%%%#
ssh_dbg_trace_points() -> [connections, tcp].

ssh_dbg_flags(tcp) -> [c];
ssh_dbg_flags(connections) -> [c].

ssh_dbg_on(tcp) -> dbg:tpl(?MODULE, accept, 3, x),
                   dbg:tpl(?MODULE, close, 2, x);

ssh_dbg_on(connections) -> dbg:tp(?MODULE,  acceptor_init, 4, x),
                           dbg:tpl(?MODULE, handle_connection, 4, x),
                           dbg:tpl(?MODULE, maybe_add_acceptor, 2, x).

ssh_dbg_off(tcp) -> dbg:ctpl(?MODULE, accept, 3),
                    dbg:ctpl(?MODULE, close, 2);

ssh_dbg_off(connections) -> dbg:ctp(?MODULE, acceptor_init, 4),
                            dbg:ctp(?MODULE, handle_connection, 4).

ssh_dbg_format(tcp, {call, {?MODULE,accept, [ListenSocket, _AcceptTimeout, _Options]}}, Stack) ->
    {skip, [{lsock,ListenSocket}|Stack]};
ssh_dbg_format(tcp, {return_from, {?MODULE,accept,3}, {ok,Sock}}, [{lsock,ListenSocket}|Stack]) ->
    {["TCP accept\n",
      io_lib:format("ListenSock: ~p~n"
                    "New Socket: ~p~n", [ListenSocket,Sock])
     ], Stack};
ssh_dbg_format(tcp, {return_from, {?MODULE,accept,3}, {error,timeout}}, [{lsock,_ListenSocket}|Stack]) ->
    {skip, Stack};
ssh_dbg_format(tcp, {return_from, {?MODULE,accept,3}, Return}, [{lsock,ListenSocket}|Stack]) ->
    {["TCP accept returned\n",
      io_lib:format("ListenSock: ~p~n"
                    "Return: ~p~n", [ListenSocket,Return])
     ], Stack}.

ssh_dbg_format(tcp, {return_from, {?MODULE,close,2}, _Return}) ->
    skip;
ssh_dbg_format(connections, {return_from, {?MODULE,acceptor_init,4}, _Ret}) ->
    skip;
ssh_dbg_format(connections, {return_from, {?MODULE,maybe_add_acceptor,2}, _Ret}) ->
    skip;
ssh_dbg_format(connections, {call, {?MODULE,handle_connection,[_Address,_Port,_Options,_Sock]}}) ->
    skip;
ssh_dbg_format(Tracepoint, Event = {call, {?MODULE, Function, Args}}) ->
    [io_lib:format("~w:~w/~w> ~s", [?MODULE, Function, length(Args)] ++
                       ssh_dbg_comment(Tracepoint, Event))];
ssh_dbg_format(Tracepoint, Event = {return_from, {?MODULE,Function,Arity}, Ret}) ->
    [io_lib:format("~w:~w/~w returned ~W> ~s", [?MODULE, Function, Arity, Ret, 2] ++
                       ssh_dbg_comment(Tracepoint, Event))].

ssh_dbg_comment(tcp, {call, {?MODULE, close, [Socket, _Options]}}) ->
    [io_lib:format("TCP close listen socket Socket: ~p~n", [Socket])];
ssh_dbg_comment(connections, {call, {?MODULE, maybe_add_acceptor, [true, AcceptorCnt]}}) ->
    [io_lib:format("(parallel_login=true) AcceptorCnt = ~p, acceptor added", [AcceptorCnt])];
ssh_dbg_comment(connections, {call, {?MODULE, maybe_add_acceptor, [ParallelLogin, AcceptorCnt]}})
  when is_integer(ParallelLogin), AcceptorCnt < ParallelLogin ->
    [io_lib:format("(parallel_login=~p) AcceptorCnt = ~p, acceptor added", [ParallelLogin, AcceptorCnt])];
ssh_dbg_comment(connections, {call, {?MODULE, maybe_add_acceptor, [ParallelLogin, AcceptorCnt]}}) ->
    [io_lib:format("(parallel_login=~p) AcceptorCnt = ~p", [ParallelLogin, AcceptorCnt])];
ssh_dbg_comment(connections, {call, {?MODULE, acceptor_init, [_AcceptorSup, _SysSup, Address, _Opts]}}) ->
    [io_lib:format("Starting LISTENER on ~s", [ssh_lib:format_address(Address)])];
ssh_dbg_comment(connections, {return_from, {?MODULE, handle_connection, 4}, {error, Error}}) ->
    [io_lib:format("Starting connection to server failed: Error = ~p", [Error])].
