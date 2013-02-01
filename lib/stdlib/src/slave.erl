%%
%% %CopyrightBegin%
%% 
%% Copyright Ericsson AB 1996-2013. All Rights Reserved.
%% 
%% The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with this software. If not, it can be
%% retrieved online at http://www.erlang.org/.
%% 
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.
%% 
%% %CopyrightEnd%
%%
-module(slave).

%% If the macro DEBUG is defined during compilation, 
%% debug printouts are done through erlang:display/1.
%% Activate this feature by starting the compiler 
%% with> erlc -DDEBUG ... 
%% or by> setenv ERL_COMPILER_FLAGS DEBUG 
%% before running make (in the OTP make system)
%% (the example is for tcsh)


-export([pseudo/1,
	 pseudo/2,
	 start/1, start/2, start/3,
	 start/5,
	 start_link/1, start_link/2, start_link/3,
	 start_master/2,
	 additional_masters/2,
	 stop/1,
	 relay/1]).

%% Internal exports 
-export([slave_start/1]).

-import(error_logger, [error_msg/2]).

-ifdef(DEBUG).
-define(dbg(Tag,Data), erlang:display({Tag,Data})).
-else.
-define(dbg(Tag,Data), true).
-endif.

-define( DIE, die_with_master ).
-define( DONT_DIE, dont_die_with_master ).

-record( start_args, {
	additional_masters,
	args,
	die,
	name,
	prog,
	tty
}).

%%
%% Types
%%
-type start_options() :: [start_option()].

-type start_option() :: {name, atom() | string()} | {args, string()} | {link, boolean()} | {rsh, string()}
	| {prog, string()} | {die_with_master, boolean()} | {tty_to_master, boolean()}
	| {additional_masters, [node()]} | {return, 'node' | 'pid'}.


%% Start a list of pseudo servers on the local node
pseudo([Master | ServerList]) ->
    pseudo(Master , ServerList);
pseudo(_) ->
    error_msg("No master node given to slave:pseudo/1~n",[]).

-spec pseudo(Master, ServerList) -> ok when
      Master :: node(),
      ServerList :: [atom()].

pseudo(_, []) -> ok;
pseudo(Master, [S|Tail]) ->
    start_pseudo(S, whereis(S), Master),
    pseudo(Master, Tail).

start_pseudo(Name, undefined, Master) ->
    X = rpc:call(Master,erlang, whereis,[Name]),
    register(Name, spawn(slave, relay, [X]));

start_pseudo(_,_,_) -> ok.  %% It's already there


%% This relay can be used to relay all messages directed to a process.

-spec relay(Pid) -> no_return() when
      Pid :: pid().

relay({badrpc,Reason}) ->
    error_msg(" ** exiting relay server ~w :~w  **~n", [self(),Reason]),
    exit(Reason);
relay(undefined) ->
    error_msg(" ** exiting relay server ~w  **~n", [self()]),
    exit(undefined);
relay(Pid) when is_pid(Pid) ->
    relay1(Pid).

relay1(Pid) ->
    receive
        X ->
            Pid ! X
    end,
    relay1(Pid).

%% start/1,2,3 --
%% start_link/1,2,3 --
%%
%% The start/1,2,3 functions are used to start a slave Erlang node.
%% The node on which the start/N functions are used is called the
%% master in the description below.
%%
%% If hostname is the same for the master and the slave,
%% the Erlang node will simply be spawned.  The only requirment for
%% this to work is that the 'erl' program can be found in PATH.
%%
%% If the master and slave are on different hosts, start/N uses
%% the 'rsh' program to spawn an Erlang node on the other host.
%% Alternative, if the master was started as
%% 'erl -sname xxx -rsh my_rsh...', then 'my_rsh' will be used instead
%% of 'rsh' (this is useful for systems where the rsh program is named
%% 'remsh').
%%
%% For this to work, the following conditions must be fulfilled:
%%
%% 1. There must be an Rsh program on computer; if not an error
%%    is returned.
%%
%% 2. The hosts must be configured to allowed 'rsh' access without
%%    prompts for password.
%%
%% The slave node will have its filer and user server redirected
%% to the master.  When the master node dies, the slave node will
%% terminate.  For the start_link functions, the slave node will
%% terminate also if the process which called start_link terminates.
%%
%% Returns: {ok, Name@Host} |
%%	    {error, timeout} |
%%          {error, no_rsh} |
%%	    {error, {already_running, Name@Host}}

-spec start(Host) -> {ok, Node} | {error, Reason} when
      Host :: atom(),
      Node :: node(),
      Reason :: timeout | no_rsh | {already_running, Node}.

start(Host) -> start(Host, []).

-spec start(Host, Name_or_options) -> {ok, Node_or_pid} | {error, Reason} when
      Host :: string() | atom(),
      Name_or_options :: atom() | start_options(),
      Node_or_pid :: node() | pid(),
      Reason :: timeout | no_rsh | {already_running, node()}.

start(Host, Name) when is_atom(Name) ->
    start(Host, [{name, Name}]);
start( Host0, Options ) when is_list(Options) ->
    Host = to_list( Host0 ),
    Name = name( Options ),
    Remote_node = node( Host, Name ),
    LinkTo = link_to( Options ),
    Rsh = rsh( Options ),
    Start_args = #start_args{
	prog=prog( Options ),
	tty=tty_to_master( Options ),
	name=Name,
	die=die_with_master( Options ),
	additional_masters=
		[to_list(X) || X <- proplists:get_value( additional_masters, Options, [] )],
	args=args( Options )
    },
    Return = proplists:get_value( return, Options, node ),
    start_return( Return,
	start_it(net_adm:ping(Remote_node), Remote_node, LinkTo, Host, Rsh, Start_args) ).

-spec start(Host, Name, Args) -> {ok, Node} | {error, Reason} when
      Host :: atom(),
      Name :: atom(),
      Args :: string(),
      Node :: node(),
      Reason :: timeout | no_rsh | {already_running, Node}.

start(Host, Name, Args) -> start(Host, [{name, Name}, {args, Args}]).

-spec start_link(Host) -> {ok, Node} | {error, Reason} when
      Host :: atom(),
      Node :: node(),
      Reason :: timeout | no_rsh | {already_running, Node}.

start_link(Host) -> start(to_list(Host), [link]).

-spec start_link(Host, Name) -> {ok, Node} | {error, Reason} when
      Host :: atom(),
      Name :: atom(),
      Node :: node(),
      Reason :: timeout | no_rsh | {already_running, Node}.

start_link(Host, Name) -> start(Host, [link, {name, Name}]).

-spec start_link(Host, Name, Args) -> {ok, Node} | {error, Reason} when
      Host :: atom(),
      Name :: atom(),
      Args :: string(),
      Node :: node(),
      Reason :: timeout | no_rsh | {already_running, Node}.

start_link(Host, Name, Args) -> start(Host, [link, {name, Name}, {args, Args}]).


start(Host, Name, Args, LinkTo, Prog) ->
    start(Host, [{name, Name}, {args, Args}, {link, LinkTo}, {prog, Prog}]).


-spec start_master(Host, Options) -> {ok, Node} | {error, Reason} when
      Host :: string(),
      Options :: [tuple()],
      Node :: node(),
      Reason :: timeout | no_rsh | {already_running, Node}.
start_master(Host, Options) ->
    start(Host, [{tty_to_master, false}, {die_with_master, false} | Options]).

-spec additional_masters(Slave_pid, Masters) -> {ok, Current_masters} | {error, Reason} when
      Slave_pid :: pid(),
      Masters :: [node()],
      Current_masters :: [node()],
      Reason :: timeout.
additional_masters( Slave_pid, Masters ) when is_pid(Slave_pid)->
    Slave_pid ! {additional_masters, erlang:self(), Masters},
    receive
	{additional_masters_ok, Slave_pid, Current_masters} -> {ok, Current_masters}
	after 32000 -> {error, timeout}
    end;
additional_masters( _Slave_pid, _Masters ) -> {error, no_slave}.

%% Stops a running node.

-spec stop(Node) -> ok when
      Node :: node().

stop(Node) ->
%    io:format("stop(~p)~n", [Node]),
    rpc:call(Node, erlang, halt, []),
    ok.

%%%----------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------

args(Options) -> proplists:get_value(args, Options, []).


die_with_master(Options) when is_list(Options) ->
    die_with_master( proplists:get_value(die_with_master, Options, true) );
die_with_master(true) -> to_list(?DIE);
die_with_master(false) -> to_list(?DONT_DIE).


link_to(Options) when is_list(Options) -> link_to( proplists:get_value(link, Options, false) );
link_to(Pid) when is_pid(Pid) -> Pid; % start/5
link_to(no_link) -> no_link; % start/5
link_to(true) -> erlang:self();
link_to(false) -> no_link.


name(Options) ->
    L = to_list( erlang:node() ),
    Name = upto($@, L),
    to_list(proplists:get_value(name, Options, Name)).


node(Host0, Name) ->
    Host =
	case net_kernel:longnames() of
	    true -> dns(Host0);
	    false -> strip_host_name(to_list(Host0));
	    ignored -> erlang:exit(not_alive)
	end,
    erlang:list_to_atom(Name ++ "@" ++ Host).


prog(Options) -> proplists:get_value(prog, Options, to_list(lib:progname())).


%% Give the user an opportunity to run another program,
%% than the "rsh".  On HP-UX rsh is called remsh; thus HP users
%% must start erlang as erl -rsh remsh.
%%
%% Also checks that the given program exists.
%%
%% Returns: {ok, RshPath} | {error, Reason}
rsh(Options) ->
    Rsh =
	case init:get_argument(rsh) of
	    {ok, [[Prog]]} -> Prog;
	    _ -> "rsh"
	end,
    case os:find_executable(proplists:get_value(rsh, Options, Rsh)) of
	false -> {error, no_rsh};
	Path -> {ok, Path}
    end.


%% The "-master" flag triggers the slave TTY output behaviour.
%% If "-master" is included when starting a node that should not die with its master,
%% that node will die with the node that started it,
%% if the master was started with slave:start/2.
%% This option makes it possible to remove "-master" for
%% nodes that should not die with their master when started from a slave node.
tty_to_master(Options) when is_list(Options) ->
    tty_to_master( proplists:get_value(tty_to_master, Options, true), erlang:node() ).

tty_to_master(true, Node) -> "-master " ++ to_list(Node);
tty_to_master(false, _Node) -> "".

%% Starts a new slave node.

start_it(pong, Remote_node, _LinkTo, _Host, _Rsh, _Start_args) ->
    {error, {already_running, Remote_node}};
start_it(pang, Remote_node, LinkTo, Host, Rsh, Start_args) ->
    Self = erlang:self(),
    erlang:spawn(fun() -> wait_for_slave(Self, Remote_node, LinkTo, Host, Rsh, Start_args) end),
    receive
	{result, Result} -> Result
    end.

start_return( node, {ok, Pid} ) ->
    {ok, erlang:node(Pid)};
start_return( pid, {ok, Pid} ) -> {ok, Pid};
start_return( _Return, Error ) -> Error.

%% Waits for the slave to start.

wait_for_slave(Parent, Remote_node, LinkTo, Host, Rsh, Start_args) ->
    Waiter = register_unique_name(0),
    case mk_cmd(Host, Rsh, Start_args, to_list(Waiter)) of
	{ok, Cmd} ->
	    Port = erlang:open_port({spawn, Cmd}, [stream]),
	    receive
		{SlavePid, slave_started} ->
		    unregister(Waiter),
		    wait_for_slave_close_port(Port, erlang:port_info(Port,id)),
		    slave_started(Parent, LinkTo, SlavePid)
	    after 32000 ->
		    %% If it seems that the node was partially started,
		    %% try to kill it.
		    wait_for_slave_close_port(Port, erlang:port_info(Port,id)),
		    case net_adm:ping(Remote_node) of
			pong ->
			    erlang:spawn(Remote_node, erlang, halt, []),
			    ok;
			_ ->
			    ok
		    end,
		    Parent ! {result, {error, timeout}}
	    end;
	Other ->
	    Parent ! {result, Other}
    end.

wait_for_slave_close_port( _Port, undefined ) -> ok;
wait_for_slave_close_port( Port, _Info ) -> erlang:port_close(Port).


slave_started(ReplyTo, no_link, Slave) when is_pid(Slave) ->
    ReplyTo ! {result, {ok, Slave}};
slave_started(ReplyTo, Master, Slave) when is_pid(Master), is_pid(Slave) ->
    process_flag(trap_exit, true),
    link(Master),
    link(Slave),
    ReplyTo ! {result, {ok, Slave}},
    one_way_link(Master, Slave).

%% This function simulates a one-way link, so that the slave node
%% will be killed if the master process terminates, but the master
%% process will not be killed if the slave node terminates.

one_way_link(Master, Slave) ->
    receive
	{'EXIT', Master, _Reason} ->
	    unlink(Slave),
	    Slave ! {nodedown, erlang:node()};
	{'EXIT', Slave, _Reason} ->
	    unlink(Master);
	_Other ->
	    one_way_link(Master, Slave)
    end.

register_unique_name(Number) ->
    Name = list_to_atom(lists:concat(["slave_waiter_", Number])),
    case catch register(Name, self()) of
	true ->
	    Name;
	{'EXIT', {badarg, _}} ->
	    register_unique_name(Number+1)
    end.


%% Makes up the command to start the nodes.
%% If the node should run on the local host, there is
%% no need to use rsh.

mk_cmd(Host, Rsh0, Args, Waiter) ->
    Node = to_list(erlang:node()),
    BasicCmd = string:join([Args#start_args.prog,
			"-detached",
			Args#start_args.tty,
			long_or_short(Args#start_args.name),
			mk_cmd_slave_start(Node, Waiter, Args#start_args.die, Args#start_args.additional_masters),
			Args#start_args.args],
		" "),
	   
    case after_char($@, Node) of
	Host ->
	    {ok, BasicCmd};
	_ ->
	    case Rsh0 of
		{ok, Rsh} ->
		    {ok, string:join([Rsh, Host, BasicCmd], " ")};
		Other ->
		    Other
	    end
    end.

mk_cmd_slave_start( Node, Waiter, Die, Additional_masters ) ->
	string:join( ["-s",
			to_list(?MODULE),
			"slave_start",
			Die,
			Waiter,
			%% Node before Additional_masters to make
			%% wait_for_master_to_die/3 send 'slave_started' to right node.
			Node | Additional_masters],
		" " ).


long_or_short(Name) ->
    case net_kernel:longnames() of
	true -> "-name " ++ Name;
	false -> "-sname " ++ Name
    end.


%% This function will be invoked on the slave, using the -s option of erl.
%% It will wait for the master node to terminate.

slave_start([Die, Waiter | Masters]=_Args) ->
    ?dbg({?MODULE, slave_start}, [_Args]),
    erlang:spawn(fun() -> wait_for_master_to_die(Die, Waiter, Masters) end).

wait_for_master_to_die(Die, Waiter, Masters) ->
    ?dbg({?MODULE, wait_for_master_to_die}, [Die, Waiter, Masters]),
    erlang:process_flag(trap_exit, true),
    [erlang:monitor_node(X, true) || X <- Masters],
    [Master | _T] = Masters,
    {Waiter, Master} ! {erlang:self(), slave_started},
    wloop(Die, erlang:node(), Masters, previous_nodedown).

wloop(?DIE, _My_node, [], _Nodedown) ->
	?dbg({?MODULE, wloop}, [[_My_node], {received, {nodedown, _Nodedown}}, halting_node] ),
	erlang:halt();
wloop(?DIE=Die, My_node, Masters, Nodedown) ->
    receive
	{nodedown, Master} ->
	    Remaining = lists:delete( Master, Masters ),
	    ?dbg({?MODULE, wloop}, [[My_node], {received, {nodedown, Master}}, {remaining, Remaining}] ),
	    wloop(Die, My_node, Remaining, Master);
	{additional_masters, From, Additional_masters} ->
	    New_masters = Masters ++ Additional_masters,
	    From ! {additional_masters_ok, erlang:self(), New_masters},
	    wloop(Die, My_node, New_masters, Nodedown);
	_Other ->
	    wloop(Die, My_node, Masters, Nodedown)
    end;
wloop(?DONT_DIE, _My_node, _Masters, _Nodedown) -> ok.

%% Just the short hostname, not the qualified, for convenience.

strip_host_name([]) -> [];
strip_host_name([$.|_]) -> [];
strip_host_name([H|T]) -> [H|strip_host_name(T)].

dns(H) -> {ok, Host} = net_adm:dns_hostname(H), Host.

to_list(X) when is_list(X) -> X;
to_list(X) when is_atom(X) -> atom_to_list(X).

upto(_, []) -> [];
upto(Char, [Char|_]) -> [];
upto(Char, [H|T]) -> [H|upto(Char, T)].

after_char(_, []) -> [];
after_char(Char, [Char|Rest]) -> Rest;
after_char(Char, [_|Rest]) -> after_char(Char, Rest).
