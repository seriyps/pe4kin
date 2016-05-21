%%%-------------------------------------------------------------------
%% @doc pe4kin application public API
%% @end
%%%-------------------------------------------------------------------

-module(pe4kin_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%%====================================================================
%% API
%%====================================================================

start(_StartType, _StartArgs) ->
    PoolOpts = application:get_env(
                 pe4kin, hackney_pool,
                 [{timeout, 150000}, {max_connections, 100}]),
    ok = hackney_pool:start_pool(pe4kin, PoolOpts),
    pe4kin_sup:start_link().

%%--------------------------------------------------------------------
stop(_State) ->
    ok.

%%====================================================================
%% Internal functions
%%====================================================================
