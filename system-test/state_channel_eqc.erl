%%% @author Thomas Arts 
%%% @doc Testing state channel fsm at system test level.
%%%
%%%      The idea is that these tests could run on UAT as well.
%%%      For that reason, we cannot assume any specific height or nonces of the root account.
%%%      The Patron is the account that has a lot of tokens and we start by reading 
%%%      that account and creating working accounts from it.
%%%
%%%
%%% @end
%%% Created : 17 May 2018 by Thomas Arts 

-module(state_channel_eqc).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_statem.hrl").

-compile([export_all, nowarn_export_all]).

%% -- State and state functions ----------------------------------------------
-record(state,{nodes = [], accounts = [], nonce_delta = 1, 
               running = [], http_ready = [],
               channels = [],
               height = 0,
               tx_hashes = [], %% symbolic !
               users = []
              }).

-record(user, {name, balance, nonce}).

-record(account, { pubkey,
                   balance,
                   privkey,
                   nonce = 0}).

-record(channel, {status, %% open | created (on chain)
                  id, 
                  port,
                  initiator,
                  total,
                  responder,
                  lock_period,
                  channel_reserve,
                  push_amount,
                  ttl,
                  tx}). 


initial_state() ->
  #state{}.


%% -- Generators -------------------------------------------------------------

systems(N) ->
  [ list_to_atom(lists:concat([node, Name])) || Name <- lists:seq(1,N) ].

%% Absolute TTLs are hard to test, thinking required
gen_ttl(Height) ->
  ?LET(TTL, choose(0, 20), Height + (20 - TTL)).

ttl(S, N) when is_integer(N) ->
  {S#state.height, N};
ttl(S, {_H, N}) ->
  {S#state.height, N};
ttl(_S, optional) ->
  optional.


at_most(X) ->
  noshrink(choose(0, max(0, X))).
  

%% -- Operations -------------------------------------------------------------

%% --- Operation: start ---
start_pre(S) ->
  length(S#state.nodes) > length(S#state.running).

start_args(S) ->
  [elements([ Name || Name <- S#state.nodes, 
                      not lists:member(Name, S#state.running)])].

start_pre(S, [Node]) ->
  not lists:member(Node, S#state.running).

start(Node) ->
  aest_nodes_mgr:start_node(Node).

start_next(S, _Value, [Node]) ->
  S#state{ running = S#state.running ++ [Node]}.

%% --- Operation: patron ---
http_ready_pre(S) ->
  S#state.running =/= [].

http_ready_args(S) ->
  [elements(S#state.running)].

http_ready_pre(S, [Node]) ->
  lists:member(Node, S#state.running) andalso not lists:member(Node, S#state.http_ready).

http_ready(Node) ->
  gettop(Node, 0, erlang:system_time(millisecond) + 8000).

http_ready_next(S, Value, [Node]) ->
  S#state{http_ready = S#state.http_ready ++ [Node],
          height = {call, ?MODULE, top_height, [Value, S#state.height]} }.

http_ready_post(_S, [_Node], Res) ->
  case Res of
    {ok, 200, _} -> true;
    _ -> false
  end.


%% --- Operation: stop ---
stop_pre(S) ->
  S#state.running =/= [].

%% stop_args(S) ->
%%   [elements(S#state.running)].

stop_pre(S, [Node]) ->
  lists:member(Node, S#state.running).

stop(Node) ->
  aest_nodes_mgr:stop_node(Node, infinity).

stop_next(S, _Value, [Node]) ->
  S#state{running = S#state.running -- [Node],
          http_ready = S#state.http_ready -- [Node]}.

%% --- add_account ---
add_account_pre(S) ->
  S#state.http_ready =/= [].

add_account_args(S) ->
  noshrink(
  [elements(S#state.http_ready), 
   patron, S#state.nonce_delta, account_gen(oneof([71, 200, 500, 1000, 0])), 
   choose(1,5), ttl(S, 200), <<"quickcheck">>]).

add_account_pre(S, [Node, _Sender, Nonce, {Name, _Balance}, Fee, TTL, _Payload]) ->
  not lists:keymember(Name, #user.name, S#state.accounts) andalso
    lists:member(Node, S#state.http_ready) andalso 
    check_ttl(S, TTL) andalso
    S#state.nonce_delta == Nonce andalso
    %% and valid
    Fee >= aec_governance:minimum_tx_fee().

add_account_adapt(S, [Node, Sender, _Nonce, NewAccount, Fee, TTL, Payload]) ->
  [Node, Sender, S#state.nonce_delta, NewAccount, Fee, ttl(S, TTL), Payload].

add_account(Node, From, Nonce, {Name, Balance}, Fee, {SeenHeight, DeltaTTL}, Payload) ->
  #{ public := PubKey, secret := PrivKey} = enacl:sign_keypair(),
  Receiver = #account{ pubkey = PubKey, balance = Balance, privkey = PrivKey },
  ets:insert(accounts, {Name, Receiver}),
  [{_, Sender}] = ets:lookup(accounts, From),
  {ok, Tx} =
    aec_spend_tx:new(#{ sender    => Sender#account.pubkey,
                        recipient => Receiver#account.pubkey,
                        amount    => Receiver#account.balance,   %% we create it with this much
                        fee       => Fee,
                        payload   => Payload,
                        nonce     => Sender#account.nonce + Nonce,
                        ttl       => SeenHeight + DeltaTTL
                        }),
  SignedTx = aetx_sign:sign(Tx, Sender#account.privkey),
  Transaction = aec_base58c:encode(transaction, aetx_sign:serialize_to_binary(SignedTx)),
  request(Node, 'PostTx', #{tx => Transaction}).

add_account_next(S, Value, [_Node, _Sender, _Nonce, {Name, Balance}, _Fee, _TTL, _Payload]) ->
  %% We assume there are always enough tokens in patron account
  S#state{ accounts = S#state.accounts ++ [#user{name = Name, balance = Balance, nonce = 0}],
           tx_hashes = [{call, ?MODULE, ok200, [Value, tx_hash]} | S#state.tx_hashes],
           nonce_delta = S#state.nonce_delta + 1}.

add_account_post(_S, [_Node, _Sender, _Nonce, _Receiver, _Fee, _TTL, _Payload], Res) ->
  case Res of
    {ok, 200, #{tx_hash := _}} -> true;
    _ -> false
  end.

add_account_features(S, [_Node, _Sender, _Nonce, _Receiver, _Fee, {SeenHeight, DeltaTTL}, _Payload], _Res) ->
  [ {accounts, length(S#state.accounts) + 1},
    {accounts, ttl_delta_overshoot, (SeenHeight + DeltaTTL) - S#state.height} ] .



%% --- Operation: open_channel ---
open_channel_pre(S) ->
  S#state.http_ready =/= [] andalso length(S#state.accounts) > 1.

open_channel_args(S) ->
  ?LET({Initiator, Fee}, {elements(S#state.accounts), choose(1,5)},
  ?LET({Responder, Reserve},
       {elements(S#state.accounts -- [Initiator]), 
        at_most(Initiator#user.balance)},
       [elements(S#state.http_ready),
        #{initiator => Initiator#user.name, 
          responder => Responder#user.name,
          initiator_amount => at_most(Initiator#user.balance - Fee),
          responder_amount => at_most(Responder#user.balance),
          lock_period => choose(0,5), %% lock period
          ttl => ttl(S, 200), %% ttl (we need height for this)
          fee => Fee, %% fee
          channel_reserve => Reserve,
          push_amount => noshrink(choose(0,200)),
          nonce => Initiator#user.nonce + 1}
       ])).

open_channel_pre(S, [Node, #{initiator := Initiator, responder := Responder, 
                             nonce := Nonce, ttl := TTL} = Tx]) ->
  InAccount = lists:keyfind(Initiator, #user.name, S#state.accounts),
  RespAccount = lists:keyfind(Responder, #user.name, S#state.accounts),
  lists:member(Node, S#state.http_ready) andalso 
    InAccount /= false andalso RespAccount /= false andalso
    InAccount#user.nonce + 1 == Nonce andalso 
    check_ttl(S, TTL) andalso 
    open_channel_valid(S, [Node, Tx]).

open_channel_valid(S, [_Node, #{initiator := Initiator, responder := Responder, 
                                fee := Fee} = Tx]) ->
  InAccount = lists:keyfind(Initiator, #user.name, S#state.accounts),
  RespAccount = lists:keyfind(Responder, #user.name, S#state.accounts),
  Responder =/= Initiator andalso
    Fee >= aec_governance:minimum_tx_fee() andalso 
    InAccount#user.balance >= maps:get(initiator_amount, Tx) + Fee andalso
    maps:get(initiator_amount, Tx) >= maps:get(channel_reserve, Tx) andalso
    maps:get(responder_amount, Tx) >= maps:get(channel_reserve, Tx) andalso
    RespAccount#user.balance >= maps:get(responder_amount, Tx).


open_channel_adapt(S, [Node, #{initiator := Initiator,  ttl := TTL} = Tx]) ->
  case lists:keyfind(Initiator, #user.name, S#state.accounts) of
    false -> false;
    InAccount ->
      [Node, Tx#{nonce => InAccount#user.nonce + 1, ttl => ttl(S, TTL)}]
  end.

open_channel(Node, #{initiator := In, responder := Resp} = Tx) ->
  [{_, Initiator}] = ets:lookup(accounts, In),
  [{_, Responder}] = ets:lookup(accounts, Resp),
  EncodedTx =
    optional_ttl(Tx#{initiator => aec_base58c:encode(account_pubkey, Initiator#account.pubkey),
                     responder => aec_base58c:encode(account_pubkey, Responder#account.pubkey)}),
  case request(Node, 'PostChannelCreate', EncodedTx) of
    {ok, 200, #{tx := TxObject}} ->
      {ok, Bin} = aec_base58c:safe_decode(transaction, TxObject),
      InitiatorSignedTx = aetx_sign:sign(aetx:deserialize_from_binary(Bin), 
                                [Initiator#account.privkey]),
      ResponderSignedTx = aetx_sign:sign(aetx:deserialize_from_binary(Bin), 
                                [Responder#account.privkey]),
      BothSigned = 
        aetx_sign:add_signatures(ResponderSignedTx, aetx_sign:signatures(InitiatorSignedTx)),
      Transaction = aec_base58c:encode(transaction, aetx_sign:serialize_to_binary(BothSigned)),
      request(Node, 'PostTx', #{tx => Transaction});
    Error ->
      Error
  end.

open_channel_next(S, Value, [_Node, #{initiator := In, responder := Resp,
                                      fee := Fee, nonce := Nonce} = Tx]) ->
  Initiator = lists:keyfind(In, #user.name, S#state.accounts),
  Responder = lists:keyfind(Resp, #user.name, S#state.accounts),
  Accounts = 
    lists:keyreplace(Resp, #user.name,
                     lists:keyreplace(In, #user.name, 
                                      S#state.accounts, 
                                      Initiator#user{ balance = Initiator#user.balance - Fee - maps:get(initiator_amount, Tx),
                                                      nonce = Nonce }),
                     Responder#user{ balance = Responder#user.balance - maps:get(responder_amount, Tx)}),
  S#state{ channels = S#state.channels ++ [ #channel{status = open,
                                                     id = {In, Nonce, Resp},
                                                     initiator = In,
                                                     responder = Resp,
                                                     total = maps:get(initiator_amount, Tx) + maps:get(responder_amount, Tx),
                                                     lock_period = maps:get(lock_period, Tx),
                                                     channel_reserve = maps:get(channel_reserve, Tx),
                                                     push_amount = maps:get(push_amount, Tx),
                                                     ttl = maps:get(ttl, Tx)} ],
           tx_hashes = [{call, ?MODULE, ok200, [Value, tx_hash]} | S#state.tx_hashes],
           accounts = Accounts }.

open_channel_post(_S, [_Node, _], Res) ->
  case Res of
    {ok, 200, #{tx_hash := _}} -> true;
    _ -> 
      Res
  end.

open_channel_features(S, [_Node, #{responder := Resp} = Tx], _) ->
  Responder = lists:keyfind(Resp, #user.name, S#state.accounts),
  [ {open_channel, responder_balance_less_responder_amount} ||
    not (Responder#user.balance >= maps:get(responder_amount, Tx)) ].

channel_account(_S, false, _) ->
  false;
channel_account(S, #channel{responder = From}, responder) ->
  lists:keyfind(From, #user.name, S#state.accounts);
channel_account(S, #channel{initiator = From}, initiator) ->  
  lists:keyfind(From, #user.name, S#state.accounts);
channel_account(S, Id, Party) when is_tuple(Id) ->
  Channel = lists:keyfind(Id, #channel.id, S#state.channels),
  channel_account(S, Channel, Party).



%% --- Operation: deposit ---
deposit_pre(S) ->
  S#state.http_ready =/= [] andalso 
    lists:keymember(created, #channel.status, S#state.channels).

deposit_args(S) ->
  ?LET({Channel, Party}, {elements([ Ch || #channel{status = created} = Ch <- S#state.channels]), 
                          oneof([initiator, responder])},
       begin
         From = channel_account(S, Channel, Party),
         [elements(S#state.http_ready),
          #{from => Party,
            channel_id => Channel#channel.id,
            amount => at_most(From#user.balance),
            ttl => ttl(S, 200),
            fee => choose(1,5),
            nonce => From#user.nonce + 1}
         ]
       end).

deposit_pre(S, [Node,
                #{channel_id := Ch, from := Party, nonce := Nonce, ttl := TTL} = Tx]) ->
  Channel = lists:keyfind(Ch, #channel.id, S#state.channels),
  Account = channel_account(S, Channel, Party),
  lists:member(Node, S#state.http_ready) andalso
    Channel /= false andalso
    Channel#channel.status == created andalso 
    Account /= false andalso Account#user.nonce + 1 == Nonce andalso
    check_ttl(S, TTL) andalso
    deposit_valid(S, Tx).

deposit_valid(S, #{channel_id := Ch, from := Party, amount := Amount, fee := Fee}) ->
  Account = channel_account(S, Ch, Party),
  Fee >= aec_governance:minimum_tx_fee() andalso 
    Account#user.balance >= Amount + Fee.

deposit_adapt(S, [Node, #{from := Party, channel_id := Ch, ttl := TTL} = Tx]) ->
  case channel_account(S, Ch, Party) of
    false -> false;
    Account ->
      [Node, Tx#{nonce => Account#user.nonce + 1, ttl => ttl(S, TTL)}]
  end.

deposit(Node, #{from := Party, channel_id := Ch} = Tx) ->
  {Initiator, OrgNonce, Responder} = Ch,
  [{_, In}] = ets:lookup(accounts, Initiator), 
  [{_, Resp}] = ets:lookup(accounts, Responder), 
  Id = aesc_channels:id(In#account.pubkey, OrgNonce, Resp#account.pubkey),
  From = if Party == initiator -> In;
            Party == responder -> Resp
         end,
  EncodedTx = 
    optional_ttl(Tx#{from => aec_base58c:encode(account_pubkey, From#account.pubkey),
                     channel_id => aec_base58c:encode(channel, Id)}),
  case request(Node, 'PostChannelDeposit', EncodedTx) of
    {ok, 200, #{tx := TxObject}} ->
      {ok, Bin} = aec_base58c:safe_decode(transaction, TxObject),
      InitiatorSignedTx = aetx_sign:sign(aetx:deserialize_from_binary(Bin), 
                                [In#account.privkey]),
      ResponderSignedTx = aetx_sign:sign(aetx:deserialize_from_binary(Bin), 
                                [Resp#account.privkey]),
      BothSigned = 
        aetx_sign:add_signatures(ResponderSignedTx, aetx_sign:signatures(InitiatorSignedTx)),
      Transaction = aec_base58c:encode(transaction, aetx_sign:serialize_to_binary(BothSigned)),
      request(Node, 'PostTx', #{tx => Transaction});
    Error ->
      Error
  end.

%% Due to adapt, Channel is the one we have in the state
deposit_next(S, Value, [_Node, #{channel_id := Ch, from := Party, fee := Fee, amount := Amount, nonce := Nonce}]) ->
  Channel = lists:keyfind(Ch, #channel.id, S#state.channels),
  Account = channel_account(S, Channel, Party),
  Accounts = 
    lists:keyreplace(Account#user.name, #user.name, 
                     S#state.accounts, 
                     Account#user{ balance = Account#user.balance - (Fee + Amount),
                                   nonce = Nonce }),
  NewChannel = Channel#channel{total = Channel#channel.total + Amount},
  Channels = lists:keyreplace(Ch, #channel.id, S#state.channels, NewChannel),
  S#state{ channels = Channels,
           tx_hashes = [{call, ?MODULE, ok200, [Value, tx_hash]} | S#state.tx_hashes],
           accounts = Accounts }.

deposit_post(_S, [_Node, _], Res) ->
  case Res of
    {ok, 200, #{tx_hash := _}} -> true;
    _ -> 
      Res
  end.

deposit_features(_S, [_, #{from := Party}], _Res) ->
  [{channel_deposit, Party}].


%% --- Operation: close_mutual ---
close_mutual_pre(S) ->
  S#state.http_ready =/= [] andalso 
    lists:keymember(created, #channel.status, S#state.channels).

close_mutual_args(S) ->
  ?LET({Channel, Fee}, {elements([ Ch || #channel{status = created} = Ch <- S#state.channels]), choose(1,5)},
       begin
         Account = channel_account(S, Channel, initiator),
           ?LET(Settle, at_most(Channel#channel.total - Fee),
                [elements(S#state.http_ready),
                 #{channel_id => Channel#channel.id,
                   initiator_amount => Settle,
                   ttl => ttl(S, 200), %% ttl (we need height for this)
                   responder_amount => Channel#channel.total - Fee - Settle ,
                   fee => Fee,
                   nonce => Account#user.nonce + 1}
                ])
       end).

close_mutual_pre(S, [Node, 
                     #{channel_id := Ch, nonce := Nonce, ttl := TTL} = Tx]) ->
  Channel = lists:keyfind(Ch, #channel.id, S#state.channels),
  Account = channel_account(S, Channel, initiator),
  lists:member(Node, S#state.http_ready) andalso
    Channel /= false andalso Channel#channel.status == created andalso
    Account /= false andalso Account#user.nonce + 1 == Nonce andalso
    check_ttl(S, TTL) andalso
    close_mutual_valid(Channel, Tx).

%% New InAmount + RespAmout + Fee == Channel.inanmount + Channel.respamount
close_mutual_valid(Channel, #{initiator_amount := InAmount, responder_amount := RespAmount, fee := Fee}) ->
  Fee >= aec_governance:minimum_tx_fee() andalso 
  InAmount + RespAmount >= Fee andalso
    Channel#channel.total == InAmount + RespAmount + Fee.

%% If the channel does not exist, we cannot replace it
%% Adapting Channel Id and other values results in too complex code
close_mutual_adapt(S, [Node, #{channel_id := Ch, ttl := TTL} = Tx]) ->
  case channel_account(S, Ch, initiator) of
    false -> false;
    Account ->
      [Node, Tx#{nonce => Account#user.nonce + 1, ttl => ttl(S, TTL)}]
  end.

close_mutual(Node, #{channel_id := Ch} = Tx) ->
  {Initiator, OrgNonce, Responder} = Ch,
  [{_, In}] = ets:lookup(accounts, Initiator), 
  [{_, Resp}] = ets:lookup(accounts, Responder), 
  Id = aesc_channels:id(In#account.pubkey, OrgNonce, Resp#account.pubkey),
  EncodedTx =
    optional_ttl(Tx#{channel_id => aec_base58c:encode(channel, Id)}),
  case request(Node, 'PostChannelCloseMutual', EncodedTx) of
    {ok, 200, #{tx := TxObject}} ->
      {ok, Bin} = aec_base58c:safe_decode(transaction, TxObject),
      InitiatorSignedTx = aetx_sign:sign(aetx:deserialize_from_binary(Bin), 
                                [In#account.privkey]),
      ResponderSignedTx = aetx_sign:sign(aetx:deserialize_from_binary(Bin), 
                                [Resp#account.privkey]),
      BothSigned = 
        aetx_sign:add_signatures(ResponderSignedTx, aetx_sign:signatures(InitiatorSignedTx)),
      Transaction = aec_base58c:encode(transaction, aetx_sign:serialize_to_binary(BothSigned)),
      request(Node, 'PostTx', #{tx => Transaction});
    Error ->
      Error
  end.

close_mutual_next(S, Value, [_Node,  #{channel_id := Ch, nonce := Nonce, 
                                       initiator_amount := IA, responder_amount := RA}]) ->
  Initiator = channel_account(S, Ch, initiator),
  Responder = channel_account(S, Ch, responder),
  Accounts =
    lists:keyreplace(Responder#user.name, #user.name,
    lists:keyreplace(Initiator#user.name, #user.name, 
                     S#state.accounts, 
                     Initiator#user{ balance = Initiator#user.balance + IA,
                                     nonce = Nonce }),
                     Responder#user{ balance = Responder#user.balance + RA } ),
  S#state{ channels = lists:keydelete(Ch, #channel.id, S#state.channels),
           tx_hashes = [{call, ?MODULE, ok200, [Value, tx_hash]} | S#state.tx_hashes],
           accounts = Accounts }.

close_mutual_post(_S, [_Node, _], Res) ->
  case Res of
    {ok, 200, #{tx_hash := _}} -> true;
    _ -> 
      Res
  end.

close_mutual_features(_S, [_, #{initiator_amount := InAmount, responder_amount := RespAmount, fee := Fee}], _Res) ->
  [{close_mutual, even} ||  (InAmount + RespAmount ) rem 2 == 0 ] ++
    [{close_mutual, odd} ||  (InAmount + RespAmount ) rem 2 == 1 ] ++ 
    [{close_mutual, to_initiator} ||  RespAmount < floor(Fee/2) ] ++
    [{close_mutual, to_responder} ||  InAmount < floor(Fee/2) ].



%% one could add deposit of open, but not created channel, this may or may not return an error channel_id not found.


%% --- Operation: balance ---
balance_pre(S) ->
  S#state.http_ready =/= [] andalso S#state.accounts =/= [].

balance_args(S) ->
  [ elements(S#state.http_ready),?LET(A, oneof(S#state.accounts), A#user.name) ].

balance_pre(S, [Node, Name]) ->
  lists:member(Node, S#state.http_ready) andalso lists:keymember(Name, #user.name, S#state.accounts).

balance(Node, Name) ->
  [{_, #account{pubkey = PubKey}}] = ets:lookup(accounts, Name),
  request(Node, 'GetAccountBalance',  #{account_pubkey => aec_base58c:encode(account_pubkey, PubKey)}).

balance_post(_S, [_, _Name], Res) ->
  %% #user{balance = Bal} = lists:keyfind(Name, #user.name, S#state.accounts), 
  case Res of
    {ok, 200, #{balance := _B}} ->
      true;  %% We don't know what the actual balance is.
    {ok, 404, #{reason := <<"Account not found">>}} ->
      true;  %% unless we mine extensively, this could happen
    Other ->
      Other
  end.


%% --- Operation: waitforblock ---
%% Only wait if there are transactions in the mempool.
waitforblock_pre(S) ->
  S#state.http_ready =/= [].

waitforblock_args(S) ->
  [elements(S#state.http_ready), S#state.tx_hashes].

waitforblock_pre(S, [Node, Hashes]) ->
  lists:member(Node, S#state.http_ready) andalso Hashes == S#state.tx_hashes.

waitforblock_adapt(S, [_Node, _Hashes]) ->
  waitforblock_args(S).
  
waitforblock(Node, Hashes) ->
  ok200(wait_blocks(Node, 1, Hashes, 60*5*1000), height).

%% Now some transactions should be on chain
waitforblock_next(S, Value, [_Node, _]) ->
  Channels =
    [ case Channel#channel.status of
        open ->
          Channel#channel{status = created};
        _ -> Channel
      end || Channel <- S#state.channels ],
  S#state{channels = Channels, 
          height = Value %% postcondition guarantees that this is an integer at runtime.
         }.

waitforblock_post(_S, [_Node, _], Res) ->
  is_integer(Res).

waitforblock_features(S, [_Node, _], _Res) ->
  [ channel_created_on_chain || lists:keymember(open, #channel.status, S#state.channels) ].


%% --- Operation: transaction_pool ---
transaction_pool_pre(S) ->
  S#state.http_ready =/= [].

transaction_pool_args(S) ->
  [elements(S#state.http_ready)].

transaction_pool_pre(S, [Node]) ->
  lists:member(Node, S#state.http_ready).

transaction_pool(Node) ->
  case request(Node, 'GetTxs', #{}) of
    {ok, 200, Transactions} ->
      Txs = [ begin
                {transaction, Trans} = aec_base58c:decode(T),
                %% Not sure all transactions in pool must be signed???
                aetx_sign:tx(aetx_sign:deserialize_from_binary(Trans))
              end || #{tx := T} <- Transactions ],
      Txs;
    Res ->
      Res
  end.

transaction_pool_post(_S, [_Node], Res) ->
  is_list(Res).



%% --- Operation: top ---
top_pre(S) ->
  S#state.http_ready =/= [].

top_args(S) ->
  [elements(S#state.http_ready)].

top_pre(S, [Node]) ->
  lists:member(Node, S#state.http_ready).

top(Node) ->
  request(Node, 'GetTop', #{}).

top_next(S, Value, [_Node]) ->
  S#state{height = {call, ?MODULE, top_height, [Value, S#state.height]} }.

top_post(_S, [_Node], Res) ->
  case Res of 
    {ok, 200, _} -> true;
    _ -> eq(Res, ok)
  end.


%%% -----------------------------------------------------------------------

final_balances([], _) ->
  undefined;
final_balances(Nodes, Names) ->
  Balances = [ balance(Node, Name) || Node <- Nodes, Name <- Names ],
  lists:usort(Balances).

%% Return all transactions that we genearated but are not yet on chain
final_transactions([], _) ->
  [];
final_transactions([Node|_], Hashes) ->
  Objs = 
    [ ok200(request(Node, 'GetTx', #{tx_hash => eqc_symbolic:eval(TxHash), tx_encoding => json}), transaction) || TxHash <- Hashes ],
  [ Obj || #{block_height := -1} = Obj <-Objs ].


%% Start using GetAccountNonce when available!
try_get_nonce(Node, PubKey) ->
  try
    {ok, 200, #{transactions := Txs}} =
      request(Node, 'GetAccountTransactions',  #{account_pubkey => aec_base58c:encode(account_pubkey, PubKey),
                                                 tx_encoding => json}),
    case [ Tx || #{tx := Tx, block_height := H} <- Txs, H /= -1 ] of
      [] -> 0;
      [Tx|_] -> 
        maps:get(nonce, Tx)
    end
  catch
    _:Reason -> 
      eqc:format("error getting patron nonce ~p -> ~p\n", [Node, Reason]),
      0
  end.


tag(_Tag, true) -> true;
tag(Tag, false) -> Tag;
tag(Tag, Other) -> {Tag, Other}. 

weight(S, open_channel) -> if length(S#state.accounts) > 1 -> 100; true -> 0 end;
weight(S, deposit) -> if length(S#state.channels) > 0 -> 50; true -> 0 end;
weight(_S, add_account) -> 10;
weight(S, close_mutual) -> if length(S#state.channels) > 0 -> 30; true -> 0 end;
weight(_S, start) -> 1;
weight(_S, stop) -> 0;
weight(_S, _) -> 1.


%% -- Generators -------------------------------------------------------------
gen_key_pair() ->
    return(crypto:generate_key(ecdh, crypto:ec_curve(secp256k1))).

account_gen(NatGen) ->
    ?LET({[Name], Balance}, {eqc_erlang_program:words(1), NatGen}, {Name, Balance}).

check_ttl(S, {Height, _}) ->
  Height == S#state.height;
check_ttl(_S, optional) ->
  true.

optional_ttl(Tx) ->
  case maps:get(ttl, Tx) of
    optional -> 
      maps:without([ttl], Tx);
    {Height, DTTL} ->
      Tx#{ttl => Height + DTTL}
  end.


%% -- Property ---------------------------------------------------------------

%% UAT keys: https://github.com/aeternity/testnet-keys/tree/master/accounts/UAT_sender_account
prop_transactions() ->
  prop_patron(10000, #account{ pubkey = <<206,167,173,228,112,201,249,157,157,78,64,8,128,168,111,
                                                 29,73,187,68,75,98,241,26,158,187,100,187,207,235,115,
                                                 254,243>>,
                                      privkey = <<230,169,29,99,60,119,207,87,113,50,157,51,84,179,188,
                                                  239,27,197,224,50,196,61,112,182,211,90,249,35,206,30,
                                                  183,77,206,167,173,228,112,201,249,157,157,78,64,8,128,
                                                  168,111,29,73,187,68,75,98,241,26,158,187,100,187,207,
                                                  235,115,254,243>>,
                                      balance = 1000000 %% ensure at least this much in patron account
                                   }, aest_docker).

prop_uat() ->
  prop_patron(15*60*1000, #account{ pubkey = <<206,167,173,228,112,201,249,157,157,78,64,8,128,168,111,
                                                 29,73,187,68,75,98,241,26,158,187,100,187,207,235,115,
                                                 254,243>>,
                                      privkey = <<230,169,29,99,60,119,207,87,113,50,157,51,84,179,188,
                                                  239,27,197,224,50,196,61,112,182,211,90,249,35,206,30,
                                                  183,77,206,167,173,228,112,201,249,157,157,78,64,8,128,
                                                  168,111,29,73,187,68,75,98,241,26,158,187,100,187,207,
                                                  235,115,254,243>>,
                                      balance = 1000000 %% ensure at least this much in patron account
                                   }, aest_uat).

%% One could run this with an arbitrary generated account 
prop_patron(FinalSleep, Patron, Backend) ->
  eqc:dont_print_counterexample(
  ?LET(Shrinking, parameter(shrinking, false),
  ?FORALL([NodeName|_] = Nodes, systems(1),
  ?FORALL(Cmds, more_commands(3, commands(?MODULE, #state{nodes = Nodes, running = [NodeName]})),
  ?SOMETIMES(if not (Shrinking orelse Backend == aest_uat) -> 2; 
                true -> 1 end,
  begin
    %% file:write_file("exs.txt", io_lib:format("Cmds = ~p\n", [Cmds]), [append]),
    DataDir = filename:absname("data"),
    Genesis = filename:join(DataDir, "accounts.json"),
    JSON = 
      jsx:encode(
        [ { aec_base58c:encode(account_pubkey, Patron#account.pubkey), Patron#account.balance } ]),
    ok = filelib:ensure_dir(Genesis),
    ok = file:write_file(Genesis, JSON),
    aest_nodes_mgr:start_link([Backend], #{data_dir => DataDir,
                                           temp_dir => "/tmp"}),
    aest_nodes_mgr:setup_nodes(
      aest_nodes:cluster(Nodes, #{ genesis => Genesis,
                                   source => {pull, "aeternity/epoch:local"},
                                   backend => Backend })),
    start(NodeName),
    http_ready(NodeName),
    PatronNonce = try_get_nonce(NodeName, Patron#account.pubkey),
    eqc:format("Patron nonce ~p\n", [PatronNonce]),
    Table = ets:new(accounts, [named_table]),
    ets:insert(accounts, {patron, Patron#account{nonce = PatronNonce}}),

    {H, S, Res} = run_commands(Cmds, [{patron_nonce, PatronNonce + 1}]),
    wait_blocks(NodeName, 1, S#state.tx_hashes, FinalSleep),  
    wait_blocks(NodeName, 1, S#state.tx_hashes, FinalSleep),  %% this is a NOP if pool is empty

    FinalTransactions = final_transactions(S#state.http_ready, S#state.tx_hashes),
    eqc:format("Transaction pool: ~p\n", [FinalTransactions]),

    FinalBalances = final_balances(S#state.http_ready, [ A#user.name || A <-S#state.accounts]),
    eqc:format("Balances ~p\n", [FinalBalances]),

    ets:delete(Table),
    aest_nodes_mgr:stop(),
    if Backend =/= aest_uat -> timer:sleep(10000);
       true -> ok
    end,

    check_command_names(Cmds,
      measure(length, commands_length(Cmds),
      measure(spend_tx, length([ 1 || {_, add_account, _} <- command_names(Cmds)]),
      aggregate(call_features(H),
        pretty_commands(?MODULE, Cmds, {H, S, Res},
                        conjunction([{result, Res == ok},
                                     {transactions, equals([ Tx || Tx <- FinalTransactions ], [])}
                                    ]))))))
  end))))).

prop_commands() ->
  ?FORALL(Cmds, commands(?MODULE, #state{nodes = [node1]}),
          not lists:keymember(close_mutual, 2, command_names(Cmds))).

%% -- helper functions

request(Node, Id, Params) ->
  Hidden =  ['GetTop', 'GetAccountBalance', 'GetAccountTransactions', 'GetTxs', 'PostTx', 'GetTx'],
  aehttp_client:request(Id, Params, 
                        [{ext_http, aest_nodes_mgr:get_service_address(Node, ext_http)}, 
                         {ct_log, case not lists:member(Id, Hidden) of
                                      true -> fun(Fmt, Args) -> io:format(Fmt++["\n"], Args) end;
                                      false -> false
                                  end}]).


wait_blocks(Node, N, Hashes, Timeout) ->
  Pool = final_transactions([Node], Hashes),
  {ok, 200, Top} = gettop(Node, 0, erlang:system_time(millisecond) + Timeout),
  case Pool of
    [] ->
      %% We're done, no transactions hanging
      {ok, 200, Top};
    _ ->
      H = maps:get(height, Top),
      gettop(Node, H+N, erlang:system_time(millisecond) + Timeout)
  end.

ok200(Resp, Field) ->
  case ok200(Resp) of
    M when is_map(M) ->
      maps:get(Field, M, undefined);
    _ -> undefined
  end.
                     
ok200({ok, 200, Value}) ->
  Value;
ok200(_) ->
  undefined.

gettop(Node, Height, Timeout) ->
  case top(Node) of
    {ok, 200, #{height := H} = Top} when H >= Height -> 
      {ok, 200, Top};
    Res ->
      case erlang:system_time(millisecond) > Timeout of
        true -> Res;
        false ->
          timer:sleep(100),
          gettop(Node, Height, Timeout)
      end
  end.
    
top_height({ok, 200, #{height := H}}, _LastSeen) ->
  H;
top_height(_, LastSeen) ->
  LastSeen.
