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

-module(riak_map_executor).
-behaviour(gen_fsm).

-export([start_link/5]).
-export([init/1, handle_event/3, handle_sync_event/4,
         handle_info/3, terminate/3, code_change/4]).

-export([wait/2]).

-record(state, {bkey,qterm,phase_pid,vnodes,keydata,ring,timeout}).

% {link, Bucket, Tag, Acc}
% {map, FunTerm, Arg, Acc}

% where FunTerm is one of:
% {modfun, Mod, Fun} : Mod and Fun are both atoms -> Mod:Fun(Obj,Keydata,Arg)
% {qfun, Fun} : Fun is an actual fun -> Fun(Obj,Keydata,Arg)

% all map funs (and link funs) must return a list of values,
% but that is not enforced at this layer

start_link(Ring, {{_, _}, _}=Input, QTerm, Timeout, PhasePid) ->
    gen_fsm:start_link(?MODULE, [Ring,Input,QTerm,Timeout,PhasePid], []);
start_link(_Ring, _BadInput, _QTerm, _Timeout, _PhasePid) ->
    {error, bad_input}.
%% @private
init([Ring,{{Bucket,Key},KeyData},QTerm0,Timeout,PhasePid]) ->
    DocIdx = riak_util:chash_key({Bucket,Key}),
    BucketProps = riak_bucket:get_bucket(Bucket, Ring),
    LinkFun = case QTerm0 of
                  {erlang, {link,_,_,_}} -> proplists:get_value(linkfun, BucketProps);
                  _ -> nop
    end,
    case LinkFun of
        linkfun_unset ->
            riak_phase_proto:mapexec_error(PhasePid,
                                            io_lib:format("linkfun unset for ~s",[Bucket])),
            {stop,no_linkfun};
        _ ->
            QTerm = case QTerm0 of
                        {_, {map, _, _, _}} -> QTerm0;
                        {Lang, {link, LB, LT, LAcc}} -> {Lang, {map, LinkFun, {LB, LT}, LAcc}}
                    end,
            N = proplists:get_value(n_val,BucketProps),
            Preflist = riak_ring:preflist(DocIdx, Ring),
            {Targets, _} = lists:split(N, Preflist),
            VNodes = try_vnode(QTerm, {Bucket,Key}, KeyData, Targets),
            {ok,wait,
             #state{bkey={Bucket,Key},qterm=QTerm,phase_pid=PhasePid,
                    vnodes=VNodes,keydata=KeyData,ring=Ring,timeout=Timeout},
             Timeout}
    end.

try_vnode(QTerm, BKey, KeyData, [{P,VN}|VNs]) ->
    gen_server:cast({riak_vnode_master, VN},
                    {vnode_map, {P,node()},
                     {self(),QTerm,BKey,KeyData}}),
    VNs.

wait(timeout, StateData=#state{phase_pid=PhasePid,vnodes=[]}) ->
    riak_phase_proto:mapexec_error(PhasePid, "all nodes failed"),
    {stop,normal,StateData};
wait(timeout, StateData=
     #state{vnodes=VNodes,qterm=QTerm,bkey=BKey,keydata=KeyData,timeout=Timeout}) ->
    {next_state, wait, StateData#state{
                         vnodes=try_vnode(QTerm, BKey, KeyData, VNodes)},
     Timeout};
wait({mapexec_error, _VN, _ErrMsg},
     StateData=#state{phase_pid=PhasePid,vnodes=[]}) ->
    riak_phase_proto:mapexec_error(PhasePid, "all nodes failed"),
    {stop,normal,StateData};
wait({mapexec_error_noretry, _VN, ErrMsg}, #state{phase_pid=PhasePid}=StateData) ->
    riak_phase_proto:mapexec_error(PhasePid, ErrMsg),
    {stop, normal, StateData};
wait({mapexec_error, _VN, _ErrMsg},StateData=
     #state{vnodes=VNodes,qterm=QTerm,bkey=BKey,keydata=KeyData,timeout=Timeout}) ->
    {next_state, wait, StateData#state{
                         vnodes=try_vnode(QTerm, BKey, KeyData, VNodes)},
     Timeout};
wait({mapexec_reply, executing, _}, #state{timeout=Timeout}=StateData) ->
    {next_state, wait, StateData, Timeout};
wait({mapexec_reply, RetVal, _VN}, StateData=#state{phase_pid=PhasePid}) ->
    riak_phase_proto:mapexec_result(PhasePid, RetVal),
    {stop,normal,StateData}.

%% @private
handle_event(_Event, _StateName, StateData) ->
    {stop,badmsg,StateData}.

%% @private
handle_sync_event(_Event, _From, _StateName, StateData) ->
    {stop,badmsg,StateData}.

%% @private
handle_info(_Info, _StateName, StateData) ->
    {stop,badmsg,StateData}.

%% @private
terminate(Reason, _StateName, _State) ->
    riak_eventer:notify(riak_map_executor, mapexec_end, Reason),
    Reason.

%% @private
code_change(_OldVsn, StateName, State, _Extra) -> {ok, StateName, State}.
