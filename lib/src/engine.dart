// Copyright 2018 The Flutter team. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:meta/meta.dart';
import 'package:rxdart/subjects.dart' show BehaviorSubject;

/// Rebloc is a modified implementation of the [Redux](https://redux.js.org/)
/// pattern using techniques more idiomatic to Flutter and Dart. Plus there's
/// blocs.
///
/// Here, [Bloc] is used to mean a business logic class that accepts input and
/// creates output solely through streams. Each [Bloc] is given two chances to
/// act in response to incoming actions: first as middleware, and again as a
/// reducer.
///
/// Rather than using functional programming techniques to combine reducers and
/// middleware, Rebloc uses a stream-based approach. A Rebloc [Store] creates
/// a dispatch stream for receiving new [Action]s, and invites [Bloc]s to
/// subscribe and manipulate the stream to apply their middleware and reducer
/// functionality. Where in Redux, one middleware function is responsible for
/// calling the next, with Rebloc a middleware function receives an action from
/// its input stream and (after logging, kicking off async APIs, dispatching new
/// actions, etc.) is responsible for emitting it on its output stream so the
/// next [Bloc] will have a chance to act. If the middleware function needs to
/// cancel the action, of course, it can just emit nothing.
///
/// After middleware processing is complete, the Stream of [Action]s is mapped
/// to one of [Accumulator]s, and each [Bloc] is given a chance to apply reducer
/// functionality in a similar manner. When finished, the resulting app state is
/// added to the [Store]'s `states` stream, and changes can be picked up by
/// [ViewModelSubscriber] widgets.
///
/// [ViewModelSubscriber] is intended to be the sole mechanism by which widgets
/// are built from the data emitted by the [Store] and wired up to dispatch
/// [Action]s to it. [ViewModelSubscriber] is similar to [StreamBuilder] in that
/// it listens to a stream and builds widgets in response, but with a few key
/// differences:
///
/// - It looks for a [StoreProvider] ancestor in order to get a reference to a
///   [Store] of matching type.
/// - It assumes the stream will always have a value on subscription (an RxDart
///   BehaviorSubject is used by [Store] to ensure this). As a result, it has no
///   mechanism for connection states or snapshots that don't contain data.
/// - It converts the app state objects it receives into view models using a
///   required `converter` function, and ignores any changes to the app state
///   that don't cause a change in its view model, limiting rebuilds.
/// - It provides to its builder method not only the most recent view model, but
///   also a reference to the [Store]'s `dispatcher` method, so new [Action]s
///   can be dispatched in response to user events like button presses.

/// A Redux-style action. Apps change their overall state by dispatching actions
/// to the [Store].
abstract class Action {
  const Action();
}

/// A function by which an [Action] can be dispatched to a [Store].
typedef void DispatchFunction(Action action);

/// An accumulator for reducer functions.
///
/// [Store] offers each [Bloc] the opportunity to apply its own reducer
/// functionality in response to incoming [Action]s by subscribing to the
/// "reducer" stream, which is of type `<Stream<Accumulator<S>>`.
///
/// A [Bloc] that does so is expected use the [Action] and [state] provided in
/// any [Accumulator] it receives to calculate a new [state], then emit it in a
/// new Accumulator with the original action and new [state].
class Accumulator<S> {
  final Action action;
  final S state;

  const Accumulator(this.action, this.state);

  Accumulator<S> copyWith(S newState) => Accumulator<S>(this.action, newState);
}

/// The context in which a middleware function executes.
///
/// In a manner similar to the streaming architecture used for reducers, [Store]
/// offers each [Bloc] the chance to apply middleware functionality to incoming
/// [Actions] by listening to the "dispatch" stream, which is of type
/// `Stream<MiddlewareContext<S>>`.
///
/// Middleware functions can examine the incoming [action] and current [state]
/// of the app, and dispatch new [Action]s using [dispatcher]. Afterward, they
/// should emit a new [MiddlewareContext] for the next [Bloc].
class MiddlewareContext<S> {
  final DispatchFunction dispatcher;
  final S state;
  final Action action;

  const MiddlewareContext(this.dispatcher, this.state, this.action);

  MiddlewareContext<S> copyWith(Action newAction) =>
      MiddlewareContext<S>(this.dispatcher, this.state, newAction);
}

/// A store for app state that manages the dispatch of incoming actions and
/// controls the stream of state objects emitted in response.
///
/// [Store] performs these tasks:
///
/// - Create a controller for the dispatch/reduce stream using an [initialState]
///   value.
/// - Wire each [Bloc] into the dispatch/reduce stream by calling its
///   [applyMiddleware] and [applyReducers] methods.
/// - Expose the [dispatcher] by which a new [Action] can be dispatched.
class Store<S> {
  final _dispatchController = StreamController<MiddlewareContext<S>>();
  final BehaviorSubject<S> states;

  Store({
    @required S initialState,
    List<Bloc<S>> blocs = const [],
  }) : states = BehaviorSubject<S>(seedValue: initialState) {
    final reducerController = StreamController<Accumulator<S>>();
    var reducerStream = reducerController.stream;
    var dispatchStream = _dispatchController.stream;

    for (Bloc<S> bloc in blocs) {
      dispatchStream = bloc.applyMiddleware(dispatchStream);
      reducerStream = bloc.applyReducer(reducerStream);
    }

    reducerController.addStream(dispatchStream.map<Accumulator<S>>(
        (context) => Accumulator(context.action, states.value)));
    reducerStream.listen((a) => states.add(a.state));
  }

  // TODO(redbrogdon): Figure out how to guarantee that only one action is in
  // the stream at a time. Also figure out if that's really necessary.
  get dispatcher => (Action action) => _dispatchController
      .add(MiddlewareContext(dispatcher, states.value, action));
}

/// A Business logic component that can apply middleware and reducer
/// functionality to a [Store] by transforming the streams passed into its
/// [applyMiddleware] and [applyReducer] methods.
abstract class Bloc<S> {
  Stream<MiddlewareContext<S>> applyMiddleware(
      Stream<MiddlewareContext<S>> input);

  Stream<Accumulator<S>> applyReducer(Stream<Accumulator<S>> input);
}

typedef Action MiddlewareFunction<S>(DispatchFunction, S, Action);
typedef S ReducerFunction<S>(S, Action);

/// A convenience [Bloc] class that handles the stream mapping bits for you.
/// Subclasses can simply override the [middleware] and [reducer] getters to
/// return their implementations.
abstract class FunctionalBloc<S> implements Bloc<S> {
  @override
  Stream<MiddlewareContext<S>> applyMiddleware(
      Stream<MiddlewareContext<S>> input) {
    return input.map((context) {
      return context.copyWith(
          middleware(context.dispatcher, context.state, context.action));
    });
  }

  @override
  Stream<Accumulator<S>> applyReducer(Stream<Accumulator<S>> input) {
    return input.map<Accumulator<S>>((accumulator) {
      return accumulator
          .copyWith(reducer(accumulator.state, accumulator.action));
    });
  }

  MiddlewareFunction<S> get middleware => (dispatcher, state, action) => action;

  ReducerFunction<S> get reducer => (state, action) => state;
}