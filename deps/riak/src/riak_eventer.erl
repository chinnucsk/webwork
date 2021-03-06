%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at

%%   http://www.apache.org/licenses/LICENSE-2.0

%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.    

%%
%% @doc
%% Riak events provide information about what is happening behind-the-scenes
%% in a Riak cluster. 
%%
%% Events are generated using {@link notify/1} or {@link notify/3}. 
%% Each event consists of a Module, an EventName, the Node on which 
%% the event is generated, and additional detail about the event. 
%%
%% A process can register to receive evets using
%% {@link add_handler/4}. Full ETS MatchSpec style matching is supported, allowing
%% the process to receive a subset of events, if desired. Filtering occurs at the
%% server level. 
%%
%% An application can register multiple event handlers, and can register multiple
%% filters for a single pid.
%%
%% Riak monitors running handlers, and automatically removes 
%% handlers of dead processors. Alternatively, an event handler
%% can be removed using {@link remove_handler/3}.

-module(riak_eventer).
-behaviour(gen_server2).
-export([start_link/0,start_link/1,stop/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-export([notify/1, notify/3]).
-export ([add_handler/4, remove_handler/3]).

-define(REMOVE_INTERVAL, 5 * 1000).

-include_lib("eunit/include/eunit.hrl").

-record (handler, {
    id,         % The id of this handler. Made from a combination 
                % of pid, matchhead, and matchguard, allowing for
                % multiple handlers from the same pid.
    desc,       % Human readable description
    pid,        % Pid of the remote process
    matchhead,  % MatchHead applied against {Module, EventName, Node, EventDetail}
    matchguard  % MatchGuard, defaults to []
}).

%% @type eventmessage() = {event, Event::event()}
%% @type event() = {EventModule::atom(), EventName::atom(), Node::atom(), EventData::term()}


%% @spec notify(Event :: event()) -> ok
%% @doc Generate an event that will be sent to all
%% handlers whose MatchSpecs match the event.
notify(Event) ->
    gen_server2:cast(riak_local_logger, {event, Event}),
    gen_server2:cast(?MODULE, {event, Event}).

%% @spec notify(EventModule :: atom(), EventName :: atom(), EventDetail :: term()) -> ok
%% @equiv notify({EventModule, EventName, node(), EventDetail})
notify(EventModule, EventName, EventDetail) ->
    notify({EventModule, EventName, node(), EventDetail}).
    
%% @spec 
%% add_handler(Pid::pid(), Desc::string(), MatchHead::tuple(), MatchGuard::tuple()) -> ok
%% EventMessage = eventmessage()
%% @doc
%% Register a process that will receive Riak events 
%% generated by the cluster. Events are Erlang messages in the form 
%% <code>{event, {EventModule, EventName, Node, EventData}}</code>.
%%
%% During operation, Riak generates events for reporting
%% and monitoring purposes. By registering an event handler
%% an application can choose to receive all or a subset of these events.
%% Riak allows for an unlimited number of event handlers (bounded only by memory).
%% When an event handler process dies, Riak automatically removes
%% that event handler from the list of event handlers. Alternatively,
%% an event handler can be programatically removed via the 
%% {@link remove_handler/3} function.
%%
%% Event handlers are judged to be unique based on the Pid, MatchHead, and MatchGuard.
%% In other words, multiple event handlers can be wired to the same pid so long as 
%% either their MatchHead or MatchGuard is different. If add_handler/4 is called twice 
%% with the same exact same Pid, MatchHead, and MatchGuard, then the old handler
%% is replaced by the new handler.
%% 
%% In addition, while registering an event handler, a 
%% developer can choose to filter the events that the 
%% event handler will receive. This filtering happens on 
%% the node generating the event. Riak generates a large number
%% of events, so tight filtering is a good idea in order to minimize
%% network traffic.
%% 
%% An event filter is specified using the MatchSpec syntax
%% established by the ETS module. See 
%% <a href="http://erlang.org/doc/apps/erts/match_spec.html">ETS MatchSpec</a>
%% for more information.
%%
%% Register for all events generated by the node 'riak@127.0.0.1':
%% <pre>
%% RiakClient:add_event_handler(self(), "Description", {'_', '_', 'riak@127.0.0.1', '_'}, [])).
%% </pre>
%%
%% Register for all events generated by the riak_vnode module:
%% <pre>
%% RiakClient:add_event_handler(self(), "Description", {riak_vnode, '_', '_', '_'}, []))
%% </pre>
%% 
%% Register for all 'put', 'get', and 'delete' events generated by the riak_vnode module:
%% <pre>
%% MatchHead = {'$1', '$2', '_', '_'},
%% MatchGuard = [
%%   {'andalso', {'==', '$1', riak_vnode}, {'orelse', {'==', '$2', get}, {'==', '$2', put}, {'==', '$2', delete}}}
%% ],
%% RiakClient:add_event_handler(self(), "Description", MatchHead, MatchGuard).
%% </pre>
%%
%% Events are sent once per matching filter. If a single process registers under more than
%% one MatchSpecs, and an event matches both MatchSpecs, then the process will
%% receive the event multiple times.
%%
%% The Description parameter is used to supply a human readable
%% string used by monitoring software to displaying connected event handlers.
%%
%% Because of the way Riak shares information between clusters, it may be 
%% a few seconds before events start being sent to the handler from all nodes.
add_handler(Pid, Description, MatchHead, MatchGuard) ->
    gen_server:call(?MODULE, {add_handler, Pid, Description, MatchHead, MatchGuard}).


%% @spec remove_handler(Pid::pid(), MatchHead::tuple(), MatchGuard::list()) -> ok
%% @doc
%% Remove the previously registered event handler. The arguments
%% supplied to remove_handler/3 must be the same arguments supplied to
%% add_handler/4. remove_handler/3 returns 'ok' regardless of whether
%% any event handlers are removed.
%%
%% Because of the way Riak shares information between clusters, it may be 
%% a few seconds before events stop being sent to the handler.
remove_handler(Pid, MatchHead, MatchGuard) ->
    HandlerID = get_handler_id(Pid, MatchHead, MatchGuard),
    gen_server:call(?MODULE, {remove_handler, HandlerID}).

%% @private
start_link() -> gen_server2:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @private
start_link(test) -> % when started this way, run a mock server (nop)
    gen_server2:start_link({local, ?MODULE}, ?MODULE, [test], []).

%% @private
init([]) -> {ok, stateless_server};
init([test]) -> {ok, test}.
    
%% @private (only used for test instances)
stop() -> gen_server2:cast(?MODULE, stop).

%% @private
handle_call({add_handler, Pid, Desc, MatchHead, MatchGuard},_From,State) -> 
    % Monitor the pid, we want to know when to remove it...
    erlang:monitor(process, Pid),

    % Add the handler...
    {ok, Ring} = riak_ring_manager:get_my_ring(),
    Handler = make_handler(Pid, Desc, MatchHead, MatchGuard),
    Ring1 = add_handler_to_ring(Handler, Ring),
    
    % Set and save the new ring...
    riak_ring_manager:set_my_ring(Ring1),
    riak_ring_manager:write_ringfile(),
    
    % Gossip the new ring...
    RandomNode = riak_ring:index_owner(Ring1,riak_ring:random_other_index(Ring1)),
    riak_connect:send_ring(RandomNode),
    {reply, ok, State};
    
handle_call({remove_handler, HandlerID},_From,State) -> 
    % Remove the handler...
    {ok, Ring} = riak_ring_manager:get_my_ring(),
    Ring1 = remove_handler_from_ring(HandlerID, Ring),
    
    % Set and save the new ring...
    riak_ring_manager:set_my_ring(Ring1),
    riak_ring_manager:write_ringfile(),
    
    % Gossip the new ring...
    RandomNode = riak_ring:index_owner(Ring1,riak_ring:random_other_index(Ring1)),
    riak_connect:send_ring(RandomNode),
    {reply, ok, State};
    
    
handle_call(_, _From, State) -> {reply, no_call_support, State}.

%% @private
handle_cast(stop, State) -> {stop,normal,State};

handle_cast({event, _Event}, test) -> {noreply,test};

handle_cast({event, Event}, State) ->
    % Get the handlers...
    {ok, Ring} = riak_ring_manager:get_my_ring(),
    Handlers = get_handlers(Ring),
    MatchingHandlers = get_matching_handlers(Event, Handlers),
    
    % Send the message to all handlers...
    [begin
        Pid = X#handler.pid,
        Pid ! {event, Event}
    end || X <- MatchingHandlers],
    {noreply, State};
    
handle_cast(_, State) -> {noreply, State}.

%% @private
handle_info({'DOWN', _, process, Pid, _}, State) ->
    % Get a 'DOWN' message, so remove any handlers from this Pid...
    {ok, Ring} = riak_ring_manager:get_my_ring(),
    OldHandlers = get_handlers(Ring),
    
    % Filter out any dead handlers...
    F = fun(Handler) -> Handler#handler.pid /= Pid end,
    NewHandlers = lists:filter(F, OldHandlers),
    
    % Write and gossip the ring if it has changed...
    RingHasChanged = OldHandlers /= NewHandlers,
    case RingHasChanged of
        true ->
            % Set and save the new ring...
            Ring1 = set_handlers(NewHandlers, Ring),
            riak_ring_manager:set_my_ring(Ring1),
            riak_ring_manager:write_ringfile(),
    
            % Gossip the new ring...
            RandomNode = riak_ring:index_owner(Ring1,riak_ring:random_other_index(Ring1)),
            riak_connect:send_ring(RandomNode);
        false -> ignore
    end,
    {noreply, State};

handle_info(_Info, State) -> {noreply, State}.

%% @private
terminate(_Reason, _State) -> ok.

%% @private
code_change(_OldVsn, State, _Extra) ->  {ok, State}.

%% make_handler/5 -
%% Create an handler record from the supplied params.
make_handler(Pid, Desc, MatchHead, MatchGuard) ->
    ID = get_handler_id(Pid, MatchHead, MatchGuard),
    #handler {
        id = ID,
        pid = Pid,
        desc = Desc,
        matchhead = MatchHead,
        matchguard = MatchGuard
    }.
    
%% add_handler_to_ring/5 -
%% Given an handler and a ring, add the handler to
%% the ring.
add_handler_to_ring(Handler, Ring) ->
    Handlers = get_handlers(Ring),
    Handlers1 = lists:keystore(Handler#handler.id, 2, Handlers, Handler),
    _Ring1 = set_handlers(Handlers1, Ring).

%% remove_handler_from_ring/4 -
%% Given part of an handler definition and a Ring, remove
%% the matching handler from the ring.
remove_handler_from_ring(Pid, MatchHead, MatchGuard, Ring) -> 
    HandlerID = get_handler_id(Pid, MatchHead, MatchGuard),
    remove_handler_from_ring(HandlerID, Ring).

%% remove_handler_from_ring/2 -
%% Given an HandlerID and a Ring, remove
%% the matching handler from the ring.
remove_handler_from_ring(HandlerID, Ring) -> 
    % Remove the handler from the ring...
    Handlers = get_handlers(Ring),
    Handlers1 = lists:keydelete(HandlerID, 2, Handlers),
    _Ring1 = set_handlers(Handlers1, Ring).
  
%% get_matching_handlers/2 -
%% Given an event and a list of #handlers, look 
%% through the handlers for all handlers that 
%% should receive the event based on their matchspec.
get_matching_handlers(Event, Handlers) ->
    F = fun(H = #handler { matchhead=MatchHead, matchguard=MatchGuard }, Matches) ->
        % NOTE: Compiled match_specs cannot be transfered across nodes,
        % so we have to recompile each time. Don't worry, it's fast.
        MS = ets:match_spec_compile([{MatchHead, MatchGuard, ['$$']}]),
        case ets:match_spec_run([Event], MS) of
            [_] -> [H|Matches];
            _ -> Matches
        end
    end,
    lists:foldl(F, [], Handlers).
    
%% Return the handlers in a ring...        
get_handlers(Ring) ->
    case riak_ring:get_meta(handlers, Ring) of
        undefined -> [];
        {ok, X} -> X
    end.
    
%% Update a ring with a new set of handlers...
set_handlers(Handlers, Ring) ->
    riak_ring:update_meta(handlers, Handlers, Ring).
    
get_handler_id(Pid, MatchHead, MatchGuard) ->
    erlang:md5(term_to_binary({Pid, MatchHead, MatchGuard})).
    
%% TESTS %%%
    
add_handler_to_ring_test() ->
    application:set_env(riak, ring_creation_size, 16),
    
    % The bare ring...
    Ring = riak_ring:fresh(),
    [] = get_handlers(Ring),
    
    % Add an handler...
    Handler1 = make_handler(self(), "Test description", {'_', '_', '_', '_'}, []),
    Ring1 = add_handler_to_ring(Handler1, Ring),
    [Handler1] = get_handlers(Ring1),
    
    % Add another handler...
    Handler2 = make_handler(self(), "Test description 1", {riak_vnode, '_', '_', '_'}, []),
    Ring2 = add_handler_to_ring(Handler2, Ring1),
    ?assert(lists:sort([Handler1, Handler2]) == lists:sort(get_handlers(Ring2))),
    
    % Remove Handler2, only Handler1 should be left...
    Ring3 = remove_handler_from_ring(Handler2#handler.pid, Handler2#handler.matchhead, Handler2#handler.matchguard, Ring2),
    [Handler1] = get_handlers(Ring3),
    
    % Remove Handler1, no handlers should be left...
    Ring4 = remove_handler_from_ring(Handler1#handler.id, Ring3),
    [] = get_handlers(Ring4),
    ok.

get_matching_handlers_test() ->
    Handlers = [
        make_handler(self(), "All 1", '_', []),
        make_handler(self(), "All 2", {'_', '_', '_', '_'}, []),
        make_handler(self(),"Only riak_vnode 1", {riak_vnode, '_', '_', '_'}, []),
        make_handler(self(),"Only riak_vnode 2", {'$1', '_', '_', '_'}, [{'==', '$1', riak_vnode}]),
        make_handler(self(),"Only riak_vnode delete", {riak_vnode, delete, '_', '_'}, []),
        make_handler(self(),"Only riak_vnode put, get, or delete", {'$1', '$2', '_', '_'}, [
            {'andalso', {'==', '$1', riak_vnode}, {'orelse', {'==', '$2', get}, {'==', '$2', put}, {'==', '$2', delete}}}
        ])
    ],
    ?assert(length(get_matching_handlers({test, ignored, ignored, ignored}, Handlers)) == 2),    
    ?assert(length(get_matching_handlers({riak_vnode, ignored, ignored, ignored}, Handlers)) == 4),    
    ?assert(length(get_matching_handlers({riak_vnode, delete, ignored, ignored}, Handlers)) == 6).
    
    