-module(hashi_ffi).

-export([create_cache_ets_table/0, get_cached/1, replace_cached/2]).

create_cache_ets_table() ->
    ets:new(daily_page_cache, [{read_concurrency, true}, set, public]).

get_cached({_, Table}) ->
    case ets:lookup_element(Table, cached, 2, none) of
        none -> {error, nil};
        Value -> {ok, Value}
    end.

replace_cached({_, Table}, Value) ->
    ets:insert(Table, {cached, Value}),
    nil.
