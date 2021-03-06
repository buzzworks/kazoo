%%%-------------------------------------------------------------------
%%% @copyright (C) 2012-2013, 2600Hz INC
%%% @doc
%%% @end
%%% @contributors
%%%   Karl Anderson <karl@2600hz.org>
%%%-------------------------------------------------------------------
-module(notify_util).

-export([send_email/3
         ,send_update/3, send_update/4
         ,render_template/3
         ,normalize_proplist/1
         ,json_to_template_props/1
         ,get_service_props/2, get_service_props/3
         ,get_rep_email/1
         ,compile_default_text_template/2
         ,compile_default_html_template/2
         ,compile_default_subject_template/2
         ,compile_default_template/3
         ,find_admin/1
         ,get_account_doc/1
        ]).

-include("notify.hrl").
-include_lib("whistle/include/wh_databases.hrl").

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec send_email/3 :: (ne_binary(), 'undefined' | binary(), term()) ->
                              'ok' | {'error', _}.
send_email(_, undefined, _) -> ok;
send_email(_, <<>>, _) -> ok;
send_email(From, To, Email) ->
    Encoded = mimemail:encode(Email),
    Relay = wh_util:to_list(whapps_config:get(<<"smtp_client">>, <<"relay">>, <<"localhost">>)),
    lager:debug("sending email to ~s from ~s via ~s", [To, From, Relay]),
    ReqId = get(callid),

    Self = self(),

    gen_smtp_client:send({From, [To], Encoded}, [{relay, Relay}]
                         ,fun(X) ->
                                  put(callid, ReqId),
                                  lager:debug("email relay responded: ~p, send to ~p", [X, Self]),
                                  Self ! {relay_response, X}
                          end),
%% The callback will receive either `{ok, Receipt}' where Receipt is the SMTP server's receipt
%% identifier,  `{error, Type, Message}' or `{exit, ExitReason}', as the single argument.
    receive
        {relay_response, {ok, _Msg}} -> ok;
        {relay_response, {error, _Type, Message}} -> {error, Message};
        {relay_response, {exit, Reason}} -> {error, Reason}
    after 10000 -> {error, timeout}
    end.

-spec send_update/3 :: (api_binary(), ne_binary(), ne_binary()) -> 'ok'.
-spec send_update/4 :: (api_binary(), ne_binary(), ne_binary(), api_binary()) -> 'ok'.
send_update(RespQ, MsgId, Status) ->
    send_update(RespQ, MsgId, Status, undefined).
send_update(undefined, _, _, _) -> lager:debug("no response queue to send update");
send_update(RespQ, MsgId, Status, Msg) ->
    Prop = props:filter_undefined(
             [{<<"Status">>, Status}
              ,{<<"Failure-Message">>, Msg}
              ,{<<"Msg-ID">>, MsgId}
              | wh_api:default_headers(?APP_NAME, ?APP_VERSION)
             ]),
    lager:debug("notification update sending to ~s", [RespQ]),
    wapi_notifications:publish_notify_update(RespQ, Prop).

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec json_to_template_props/1 :: ('undefined' | wh_json:object()) -> 'undefined' | wh_proplist().
json_to_template_props(undefined) -> undefined;
json_to_template_props(JObj) ->
    normalize_proplist(wh_json:recursive_to_proplist(JObj)).

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec normalize_proplist/1 :: (wh_proplist()) -> wh_proplist().
normalize_proplist(Props) ->
    [normalize_proplist_element(Elem) || Elem <- Props].

normalize_proplist_element({K, V}) when is_list(V) ->
    {normalize_value(K), normalize_proplist(V)};
normalize_proplist_element({K, V}) when is_binary(V) ->
    {normalize_value(K), mochiweb_html:escape(V)};
normalize_proplist_element({K, V}) ->
    {normalize_value(K), V};
normalize_proplist_element(Else) ->
    Else.

normalize_value(Value) ->
    binary:replace(wh_util:to_lower_binary(Value), <<"-">>, <<"_">>, [global]).

%%--------------------------------------------------------------------
%% @public
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec compile_default_text_template/2 :: (atom(), ne_binary()) -> {'ok', atom()}.
-spec compile_default_html_template/2 :: (atom(), ne_binary()) -> {'ok', atom()}.
-spec compile_default_subject_template/2 :: (atom(), ne_binary()) -> {'ok', atom()}.
-spec compile_default_template/3 :: (atom(), ne_binary(), atom()) -> {'ok', atom()}.

compile_default_text_template(TemplateModule, Category) ->
    compile_default_template(TemplateModule, Category, default_text_template).

compile_default_html_template(TemplateModule, Category) ->
    compile_default_template(TemplateModule, Category, default_html_template).

compile_default_subject_template(TemplateModule, Category) ->
    compile_default_template(TemplateModule, Category, default_subject_template).

compile_default_template(TemplateModule, Category, Key) ->
    {ok, TemplateModule} = erlydtl:compile(whapps_config:get(Category, Key), TemplateModule).

%%--------------------------------------------------------------------
%% @public
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec render_template/3 :: (api_binary(), atom(), wh_proplist()) ->
                                   {'ok', iolist()} |
                                   {'error', term()}.
render_template(undefined, DefaultTemplate, Props) ->
    lager:debug("rendering default ~s template", [DefaultTemplate]),
    DefaultTemplate:render(Props);
render_template(Template, DefaultTemplate, Props) ->
    try
        CustomTemplate = wh_util:to_atom(list_to_binary([couch_mgr:get_uuid(), "_"
                                                        ,wh_util:to_binary(DefaultTemplate)
                                                        ])
                                         ,true),
        lager:debug("compiling custom ~s template", [DefaultTemplate]),
        {ok, CustomTemplate} = erlydtl:compile(Template, CustomTemplate),

        lager:debug("rendering custom template ~s", [CustomTemplate]),
        Result = CustomTemplate:render(Props),

        code:purge(CustomTemplate),
        code:delete(CustomTemplate),
        Result
    catch
        _:_E ->
            lager:debug("error compiling custom ~s template: ~p", [DefaultTemplate, _E]),
            render_template(undefined, DefaultTemplate, Props)
    end.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% determine the service name, provider, and url. Hunts (in order)
%% in the event, parent account notification object, and then default.
%% @end
%%--------------------------------------------------------------------
-spec get_service_props/2 :: (wh_json:object(), ne_binary()) -> wh_proplist().
-spec get_service_props/3 :: (wh_json:object(), wh_json:object(), ne_binary()) -> wh_proplist().

get_service_props(Account, ConfigCat) ->
    get_service_props(wh_json:new(), Account, ConfigCat).

get_service_props(Request, Account, ConfigCat) ->
    DefaultUrl = wh_json:get_ne_value(<<"service_url">>, Request
                                      ,whapps_config:get(ConfigCat, <<"default_service_url">>, <<"http://apps.2600hz.com">>)),
    DefaultName = wh_json:get_ne_value(<<"service_name">>, Request
                                       ,whapps_config:get(ConfigCat, <<"default_service_name">>, <<"VOIP Services">>)),
    DefaultProvider = wh_json:get_ne_value(<<"service_provider">>, Request
                                           ,whapps_config:get(ConfigCat, <<"default_service_provider">>, <<"2600hz">>)),
    DefaultNumber = wh_json:get_ne_value(<<"support_number">>, Request
                                           ,whapps_config:get(ConfigCat, <<"default_support_number">>, <<"(415) 886-7900">>)),
    DefaultEmail = wh_json:get_ne_value(<<"support_email">>, Request
                                        ,whapps_config:get(ConfigCat, <<"default_support_email">>, <<"support@2600hz.com">>)),
    UnconfiguredFrom = list_to_binary([<<"no_reply@">>, wh_util:to_binary(net_adm:localhost())]),
    DefaultFrom = wh_json:get_ne_value(<<"send_from">>, Request
                                       ,whapps_config:get(ConfigCat, <<"default_from">>, UnconfiguredFrom)),
    Tree = wh_json:get_value(<<"pvt_tree">>, Account, []),
    [_, Module] = binary:split(ConfigCat, <<".">>),
    case Tree =/= [] andalso couch_mgr:open_doc(?WH_ACCOUNTS_DB, lists:last(Tree)) of
        {ok, JObj} ->
            lager:debug("looking for notifications '~s' service info in: ~s", [Module, wh_json:get_value(<<"_id">>, JObj)]),
            [{<<"url">>, wh_json:get_value([<<"notifications">>, Module, <<"service_url">>], JObj, DefaultUrl)}
             ,{<<"name">>, wh_json:get_value([<<"notifications">>, Module, <<"service_name">>], JObj, DefaultName)}
             ,{<<"provider">>, wh_json:get_value([<<"notifications">>, Module, <<"service_provider">>], JObj, DefaultProvider)}
             ,{<<"support_number">>, wh_json:get_value([<<"notifications">>, Module, <<"support_number">>], JObj, DefaultNumber)}
             ,{<<"support_email">>, wh_json:get_value([<<"notifications">>, Module, <<"support_email">>], JObj, DefaultEmail)}
             ,{<<"send_from">>, wh_json:get_value([<<"notifications">>, Module, <<"send_from">>], JObj, DefaultFrom)}
             ,{<<"host">>, wh_util:to_binary(net_adm:localhost())}
            ];
        _E ->
            lager:debug("failed to find parent for notifications '~s' service info: ~p", [Module, _E]),
            [{<<"url">>, DefaultUrl}
             ,{<<"name">>, DefaultName}
             ,{<<"provider">>, DefaultProvider}
             ,{<<"support_number">>, DefaultNumber}
             ,{<<"support_email">>, DefaultEmail}
             ,{<<"send_from">>, DefaultFrom}
             ,{<<"host">>, wh_util:to_binary(net_adm:localhost())}
            ]
    end.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Try to find the email address of a sub_account_rep for a given
%% account object
%% @end
%%--------------------------------------------------------------------
-spec get_rep_email/1 :: (wh_json:object()) -> api_binary().
get_rep_email(JObj) ->
    AccountId = wh_json:get_value(<<"pvt_account_id">>, JObj),
    case wh_json:get_value(<<"pvt_tree">>, JObj, []) of
        [] -> undefined;
        Tree -> get_rep_email(lists:reverse(Tree), AccountId)
    end.

get_rep_email([], _) -> undefined;
get_rep_email([Parent|Parents], AccountId) ->
    ParentDb = wh_util:format_account_id(Parent, encoded),
    ViewOptions = [include_docs
                   ,{key, AccountId}
                  ],
    lager:debug("attempting to find sub account rep for ~s in parent account ~s", [AccountId, Parent]),
    case couch_mgr:get_results(ParentDb, <<"sub_account_reps/find_assignments">>, ViewOptions) of
        {ok, [Result|_]} ->
            case wh_json:get_value([<<"doc">>, <<"email">>], Result) of
                undefined ->
                    lager:debug("found rep but they have no email, attempting to get email of admin"),
                    wh_json:get_value(<<"email">>, find_admin(ParentDb));
                Else ->
                    lager:debug("found rep but email: ~s", [Else]),
                    Else
            end;
        _E ->
            lager:debug("failed to find rep for sub account, attempting next parent"),
            get_rep_email(Parents, Parents)
    end.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% try to find the first user with admin privileges and an email given
%% a sub account object or sub account db name.
%% @end
%%--------------------------------------------------------------------
-type account_ids() :: ne_binaries().
-spec find_admin/1 :: (api_binary() | account_ids() | wh_json:object()) -> wh_json:object().
find_admin(undefined) -> wh_json:new();
find_admin([]) -> wh_json:new();
find_admin(Account) when is_binary(Account) ->
    AccountDb = wh_util:format_account_id(Account, encoded),
    AccountId = wh_util:format_account_id(Account, raw),
    case couch_mgr:open_cache_doc(AccountDb, AccountId) of
        {error, _} -> find_admin([AccountId]);
        {ok, JObj} ->
            Tree = wh_json:get_value(<<"pvt_tree">>, JObj, []),
            find_admin([AccountId | lists:reverse(Tree)])
    end;
find_admin([AcctId|Tree]) ->
    AccountDb = wh_util:format_account_id(AcctId),
    ViewOptions = [{key, <<"user">>}
                   ,include_docs
                  ],
    case couch_mgr:get_results(AccountDb, <<"maintenance/listing_by_type">>, ViewOptions) of
        {ok, Users} ->
            case [User
                  || User <- Users
                         ,wh_json:get_value([<<"doc">>, <<"priv_level">>], User) =:= <<"admin">>
                         ,wh_json:get_ne_value([<<"doc">>, <<"email">>], User) =/= undefined
                 ]
            of
                [] -> find_admin(Tree);
                [Admin|_] -> wh_json:get_value(<<"doc">>, Admin)
            end;
        _E ->
            lager:debug("faild to find users in ~s: ~p", [AccountDb, _E]),
            find_admin(Tree)
    end;
find_admin(Account) ->
    find_admin([ wh_json:get_value(<<"pvt_account_id">>, Account)
                 | lists:reverse(wh_json:get_value(<<"pvt_tree">>, Account, []))
               ]).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% given a notification event try to open the account definition doc
%% @end
%%--------------------------------------------------------------------
-spec get_account_doc/1 :: (wh_json:object()) ->
                                   {'ok', wh_json:object()} |
                                   {'error', term()} |
                                   'undefined'.
get_account_doc(JObj) ->
    case {wh_json:get_value(<<"Account-DB">>, JObj), wh_json:get_value(<<"Account-ID">>, JObj)} of
        {undefined, undefined} -> undefined;
        {undefined, Id1} ->
            couch_mgr:open_doc(wh_util:format_account_id(Id1, encoded), Id1);
        {Id2, undefined} ->
            couch_mgr:open_doc(Id2, wh_util:format_account_id(Id2, raw));
        {Db, AccountId} ->
            couch_mgr:open_doc(Db, AccountId)
    end.
