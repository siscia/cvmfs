%%%-------------------------------------------------------------------
%%% This file is part of the CernVM File System.
%%%
%%% @doc cvmfs_auth public API
%%%
%%% @end
%%%
%%%-------------------------------------------------------------------

-module(cvmfs_auth).

-compile([{parse_transform, lager_transform}]).

-behaviour(gen_server).

%% API
-export([start_link/0
        ,check_key_for_repo_path/3
        ,add_key/3, remove_key/1
        ,add_repo/2, remove_repo/1
        ,get_repos/0, get_keys/0
        ,check_hmac/3
        ,reload_repo_config/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

%% Records

-record(repo, {
          % the FQDN of the repository
          name :: binary(),
          % public id of the keys registered to modify this repo
          key_ids :: [binary()]
         }).

-record(key, {
          key_id :: binary(),
          secret :: binary(),
          path :: binary()
         }).


%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @end
%%--------------------------------------------------------------------
-spec start_link() -> {ok, Pid} | ignore | {error, Error}
                          when Pid :: pid(),
                               Error :: {already_start, pid()} | term().
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).


-spec check_key_for_repo_path(KeyId, Repo, Path) -> ok | {error,
                                                          invalid_repo |
                                                          invalid_path |
                                                          invalid_key}
                                                        when KeyId :: binary(),
                                                             Repo :: binary(),
                                                             Path :: binary().
check_key_for_repo_path(KeyId, Repo, Path) ->
    gen_server:call(?MODULE, {auth_req, check_key_for_repo_path, {KeyId, Repo, Path}}).


-spec add_key(KeyId :: binary(), Secret :: binary(), Path :: binary())-> ok.
add_key(KeyId, Secret, Path) ->
    gen_server:call(?MODULE, {auth_req, add_key, {KeyId, Secret, Path}}).


-spec remove_key(KeyId :: binary()) -> ok.
remove_key(KeyId) ->
    gen_server:call(?MODULE, {auth_req, remove_key, KeyId}).


-spec add_repo(Repo :: binary(), KeyIds :: [binary()]) -> ok.
add_repo(Repo, KeyIds) ->
    gen_server:call(?MODULE, {auth_req, add_repo, {Repo, KeyIds}}).


-spec remove_repo(Repo :: binary()) -> ok.
remove_repo(Repo) ->
    gen_server:call(?MODULE, {auth_req, remove_repo, Repo}).


-spec get_repos() -> Repos :: [{binary(), [binary()]}].
get_repos() ->
    gen_server:call(?MODULE, {auth_req, get_repos}).


-spec get_keys() -> Keys :: [{binary(), binary()}].
get_keys() ->
    gen_server:call(?MODULE, {auth_req, get_keys}).


-spec check_hmac(Message, KeyId, HMAC) -> boolean()
                                              when Message :: binary(),
                                                   KeyId :: binary(),
                                                   HMAC :: binary().
check_hmac(Message, KeyId, HMAC) ->
    gen_server:call(?MODULE, {auth_req, check_hmac, {Message, KeyId, HMAC}}).


-spec reload_repo_config() -> ok | {error, Reason}
                                  when Reason :: term().
reload_repo_config() ->
    gen_server:call(?MODULE, {auth_req, reload_repo_config}).


%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% Arguments:
%%   RepoList - list of managed repositories
%%   Keys - key list ( [{keyid, secret}] )
%%
%% @end
%%--------------------------------------------------------------------
init([]) ->
    {ok, MnesiaSchemaLocation} = application:get_env(mnesia, schema_location),
    AllNodes = [node() | nodes()],
    CopyMode = case MnesiaSchemaLocation of
                   disc ->
                       {disc_copies, AllNodes};
                   ram ->
                       {ram_copies, AllNodes}
               end,
    mnesia:create_table(repo, [CopyMode
                              ,{type, set}
                              ,{attributes, record_info(fields, repo)}]),
    mnesia:create_table(key, [CopyMode
                             ,{type, set}
                             ,{attributes, record_info(fields, key)}]),
    ok = mnesia:wait_for_tables([repo, key], 10000),

    p_reload_repo_config(),
    lager:info("Repository configuration finished."),

    {ok, []}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @end
%%--------------------------------------------------------------------
handle_call({auth_req, check_key_for_repo_path, {KeyId, Repo, Path}}, _From, State) ->
    Reply = p_check_key_for_repo_path(KeyId, Repo, Path),
    {reply, Reply, State};
handle_call({auth_req, add_key, {KeyId, Secret, Path}}, _From, State) ->
    Reply = p_add_key(KeyId, Secret, Path),
    {reply, Reply, State};
handle_call({auth_req, remove_key, Key}, _From, State) ->
    Reply = p_remove_key(Key),
    {reply, Reply, State};
handle_call({auth_req, add_repo, {Repo, KeyIds}}, _From, State) ->
    Reply = p_add_repo(Repo, KeyIds),
    {reply, Reply, State};
handle_call({auth_req, remove_repo, Repo}, _From, State) ->
    Reply = p_remove_repo(Repo),
    {reply, Reply, State};
handle_call({auth_req, get_repos}, _From, State) ->
    Reply = p_get_repos(),
    {reply, Reply, State};
handle_call({auth_req, get_keys}, _From, State) ->
    Reply = p_get_keys(),
    {reply, Reply, State};
handle_call({auth_req, check_hmac, {Message, KeyId, HMAC}}, _From, State) ->
    Reply = p_check_hmac(Message, KeyId, HMAC),
    {reply, Reply, State};
handle_call({auth_req, reload_repo_config}, _From, State) ->
    Reply = p_reload_repo_config(),
    {reply, Reply, State}.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @end
%%--------------------------------------------------------------------
handle_cast(Msg, State) ->
    lager:info("Cast received: ~p -> noreply", [Msg]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @end
%%--------------------------------------------------------------------
handle_info(Info, State) ->
    lager:warning("Unknown message received: ~p", [Info]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @end
%%--------------------------------------------------------------------
terminate(Reason, _State) ->
    lager:info("Terminating with reason: ~p", [Reason]),
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @end
%%--------------------------------------------------------------------
code_change(OldVsn, State, _Extra) ->
    lager:info("Code change request received. Old version: ~p", [OldVsn]),
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec p_check_key_for_repo_path(KeyId, Repo, Path) -> ok | {error,
                                                            invalid_repo |
                                                            invalid_key |
                                                            invalid_path}
                                   when KeyId :: binary(),
                                        Repo :: binary(),
                                        Path :: binary().
p_check_key_for_repo_path(KeyId, Repo, Path) ->
    T1 = fun() ->
                 case mnesia:read(repo, Repo) of
                     [#repo{key_ids = KeyIds} | _] ->
                         KeyValidForRepo = lists:member(KeyId, KeyIds),
                         case KeyValidForRepo of
                             true ->
                                 case mnesia:read(key, KeyId) of
                                     [#key{path = AllowedPath} | _] ->
                                         Overlapping = cvmfs_path_util:are_overlapping(Path, AllowedPath),
                                         IsSubPath = size(Path) >= size(AllowedPath),
                                         case Overlapping and IsSubPath of
                                             true ->
                                                 ok;
                                             false ->
                                                 {error, invalid_path}
                                         end;
                                     _ ->
                                         {error, invalid_path}
                                 end;
                             false ->
                                 {error, invalid_key}
                         end;
                     _ ->
                         {error, invalid_repo}
                 end
         end,
    {atomic, Result} = mnesia:transaction(T1),
    Result.


-spec p_add_key(KeyId :: binary(), Secret :: binary(), Path :: binary()) -> ok.
p_add_key(KeyId, Secret, Path) ->
    T = fun() ->
                mnesia:write(#key{key_id = KeyId, secret = Secret, path = Path})
        end,
    {atomic, Result} = mnesia:sync_transaction(T),
    Result.


-spec p_remove_key(Key :: binary()) -> ok.
p_remove_key(Key) ->
    T = fun() ->
                mnesia:delete({key, Key})
        end,
    {atomic, Result} = mnesia:sync_transaction(T),
    Result.


-spec p_add_repo(Repo :: binary(), KeyIds :: [binary()]) -> ok.
p_add_repo(Repo, KeyIds) ->
    T = fun() ->
                mnesia:write(#repo{name = Repo, key_ids = KeyIds})
        end,
    {atomic, Result} = mnesia:sync_transaction(T),
    Result.


-spec p_remove_repo(Repo :: binary()) -> ok.
p_remove_repo(Repo) ->
    T = fun() ->
                mnesia:delete({repo, Repo})
        end,
    {atomic, Result} = mnesia:sync_transaction(T),
    Result.


-spec p_get_repos() -> Repos :: [{binary(), [binary()]}].
p_get_repos() ->
    T = fun() ->
                mnesia:foldl(fun(#repo{name = Repo, key_ids = KeyIds}, Acc) ->
                                     [{Repo, KeyIds} | Acc]
                             end, [], repo)
        end,
    {atomic, Result} = mnesia:transaction(T),
    Result.


-spec p_get_keys() -> Keys :: [{binary(), binary()}].
p_get_keys() ->
    T = fun() ->
                mnesia:foldl(fun(#key{key_id = Id, path = Path}, Acc) ->
                                     [{Id, Path} | Acc]
                             end, [], key)
        end,
    {atomic, Result} = mnesia:transaction(T),
    Result.


-spec p_check_hmac(Message :: binary(), KeyId :: binary(), HMAC :: binary()) -> boolean().
p_check_hmac(Message, KeyId, HMAC) ->
    T = fun() ->
                case mnesia:read(key, KeyId) of
                    [#key{key_id = KeyId, secret = Secret} | _] ->
                        {ok, Secret};
                    _ ->
                        error
                end
        end,
    {atomic, Result} = mnesia:transaction(T),
    case Result of
        {ok, Secret} ->
            HMAC =:= cvmfs_auth_util:compute_hmac(Secret, Message);
        _ ->
            false
    end.


-spec populate_key_table(Keys :: [#{atom() := binary()}]) -> boolean().
populate_key_table(Keys) ->
    T = fun() ->
        lists:foreach(
            fun(#{id := Id, secret := Secret, path := Path}) ->
                mnesia:write(#key{key_id = Id, secret = Secret, path = Path})
            end,
            Keys)
    end,
    {atomic, Result} = mnesia:sync_transaction(T),
    Result.


-spec populate_repo_table(RepoList :: #{binary() => [binary()]}) -> boolean().
populate_repo_table(RepoList) ->
    T = fun() ->
        lists:all(
            fun(V) -> V =:= ok end,
            [mnesia:write(
                #repo{name = Repo, key_ids = KeyIds}) || #{domain := Repo,
                                                           keys := KeyIds} <- RepoList])
    end,
    {atomic, Result} = mnesia:sync_transaction(T),
    Result.


-spec p_reload_repo_config() -> ok | {error, Reason}
                                    when Reason :: term().
p_reload_repo_config() ->
    Cfg = config:read(repo_config, config:default_repo_config()),
    RepoCfg = maps:get(repos, Cfg),
    KeyCfg = maps:get(keys, Cfg),

    {atomic, ok} = mnesia:clear_table(repo),
    {atomic, ok} = mnesia:clear_table(key),

    Repos = config:load_repos(RepoCfg),
    Keys = config:load_keys(KeyCfg, Repos),

    populate_repo_table(Repos),
    populate_key_table(Keys),
    ok.
