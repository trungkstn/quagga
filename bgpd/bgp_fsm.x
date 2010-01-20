/* BGP-4 Finite State Machine
 * From RFC1771 [A Border Gateway Protocol 4 (BGP-4)]
 * Copyright (C) 1996, 97, 98 Kunihiro Ishiguro
 *
 * Recast for pthreaded bgpd: Copyright (C) Chris Hall (GMCH), Highwayman
 *
 * This file is part of GNU Zebra.
 *
 * GNU Zebra is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published
 * by the Free Software Foundation; either version 2, or (at your
 * option) any later version.
 *
 * GNU Zebra is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with GNU Zebra; see the file COPYING.  If not, write to the
 * Free Software Foundation, Inc., 59 Temple Place - Suite 330,
 * Boston, MA 02111-1307, USA.
 */

#include <zebra.h>
//#include "bgpd/bgp.h"

#include "log.h"

#include "bgpd/bgp_session.h"
#include "bgpd/bgp_connection.h"
#include "bgpd/bgp_notification.h"
#include "bgpd/bgp_fsm.h"
#include "bgpd/bgp_msg_write.h"

#include "lib/qtimers.h"
#include "lib/sockunion.h"

#include "bgpd/bgp_debug.h"
#include "bgpd/bgp_network.h"
#include "bgpd/bgp_dump.h"

/*==============================================================================
 * The BGP Finite State Machine
 *
 * The state machine is represented as a table, indexed by [state, event],
 * giving an action to be performed to deal with the event and the state that
 * will advance to (or stay at).
 *
 * In some cases the action routine may override the the default new state.
 *
 * When a new state is entered, bgp_fsm_state_change() is called to complete
 * the transition (in particular to set/unset timers).
 *
 * The fsm action functions are called with the session locked.
 *
 *------------------------------------------------------------------------------
 * FSM "events"
 *
 * These are raised when:
 *
 *   * the BGP Engine receives instructions from the Routeing Engine
 *
 *   * some I/O operations complete
 *
 *   * timers go off
 *
 * and the mechanism is to call bgp_fsm_event().
 *
 * Note that the event is dealt with *immediately* -- there is no queueing of
 * events.  This avoids the problem of the state of the connection being
 * "out of date" until its event queue is emptied, and the problem of the state
 * changing between the raising of an event and dealing with same.
 *
 * The downside is that need to deal with the possibility of events being
 * raised while the FSM is in some indeterminate state while processing an
 * event for the current connection.  This requires a little care.
 *
 * Timers, messages, and qpselect actions all occur outside the FSM.  So there
 * is no problem there.
 *
 * However, the FSM does some I/O operations -- notably write() and connect().
 * These may complete immediately, and may need to trigger a new event.  To
 * handle this, the connection can set a "post" event, to be processed at the
 * tail end of the current event processing.
 *
 * Note that there is only one level of "post" event.  The FSM only ever issues
 * one I/O operation per event.  (It's a RULE.)
 *
 *------------------------------------------------------------------------------
 * Primary and Secondary Connections
 *
 * To support BGP's "symmetrical" open strategy, this code allows for two
 * connections to be made for a session -- one connect() and one accept().
 * If two connections are made, only one will reach OpenConfirm state and
 * hence Established.
 *
 * The session->accept flag is set iff the secondary connection is prepared to
 * accept a connection.  The flag is cleared as soon as a connection is
 * accepted (or if something goes wrong while waiting for or making an accept()
 * connection).
 *
 * When a session is enabled, the allowed connections are initialised and
 * a BGP_Start event issued for each one.
 *
 * Up to Established state, the primary connection will be the out-bound
 * connect() connection (if allowed) and the secondary will be the in-bound
 * accept() connection (if allowed).  In Established state, the primary
 * connection is the one that won the race -- any other connection is snuffed
 * out.
 *
 * As per the RFC, collision detection/resolution is performed when an OPEN
 * message is received -- that is, as the connection attempts to advance to
 * OpenConfirm state.  At that point, if the sibling is in OpenConfirm state,
 * then one of the two connections is closed (and will go Idle once the
 * NOTIFICATION has been sent).
 *
 * See below for a discussion of the fall back to Idle -- the losing connection
 * will remain comatose until the winner either reaches Established (when the
 * loser is snuffed out) or the winner falls back to Idle (when the
 * IdleHoldTimer for the loser is set, and it will be awoken in due course).
 *
 * NB: the RFC talks of matching source/destination and destination/source
 *     addresses of connections in order to detect collisions.  This code
 *     uses only the far end address to detect collisions.  It does so
 *     implicitly because the in-bound connection is matched with the out-
 *     bound one using the peer's known IP address -- effectively its name.
 *
 *     [It is not deemed relevant if the local addresses for the in- and out-
 *      bound connections are different.]
 *
 *     The RFC further says "the local system MUST examine all of its
 *     connections that are in OpenConfirm state" ... "If, among these
 *     connections, there is a connection to a remote BGP speaker whose BGP
 *     identifier equals the one in the OPEN message, and this connection
 *     collides with [it]" ... then must resolve the collision.
 *
 *     This code almost does this, but:
 *
 *       * there can only be one connection that collides (i.e. only one other
 *         which has the same remote end address), and that is the sibling
 *         connection.
 *
 *         So there's not a lot of "examining" to be done.
 *
 *       * the RFC seems to accept that there could be two distinct connections
 *         with the same remote end address, but *different* BGP Identifiers.
 *
 *         As far as Quagga is concerned, that is impossible.  The remote end
 *         IP address is the name of the peering session, and there cannot
 *         be two peering sessions with the same name.  It follows that Quagga
 *         requires that the "My AS" and the "BGP Identifier" entries in the
 *         OPEN messages from a given remote end IP address MUST MATCH !
 *
 *------------------------------------------------------------------------------
 * Exception Handling.
 *
 * The FSM proceeds in three basic phases:
 *
 *   1) attempting to establish a TCP connection: Idle/Active/Connect
 *
 *      In this phase there is no connection for the other end to close !
 *
 *      Idle is a "stutter step" which becomes longer each time the FSM falls
 *      back to Idle, which it does if the process fails in OpenSent or
 *      OpenConfirm.
 *
 *      Cannot fail in Idle !
 *
 *      In Active/Connect any failure causes the FSM to stop trying to connect,
 *      then it does nothing further until the end of the ConnectRetryTimer
 *      interval -- at which point it will try again, re-charging the timer.
 *      (That is usually 120 seconds (less jitter) -- so in the worst case, it
 *      will try to do something impossible every 90-120 seconds.)
 *
 *      A connection may fall back to Idle from OpenSent/OpenConfirm (see
 *      below).  While one connection is OpenSent or OpenConfirm don't really
 *      want to start another TCP connection in competition.  So, on entry
 *      to Idle:
 *
 *        * if sibling exists and is in OpenSent or OpenConfirm:
 *
 *            - do not change the IdleHoldTimer interval.
 *            - do not set the IdleHoldTimer (with jitter).
 *            - set self "comatose".
 *
 *        * otherwise:
 *
 *            - increase the IdleHoldTimer interval.
 *            - set the IdleHoldTimer.
 *
 *          and if sibling exists and is comatose:
 *
 *            - set *its* IdleHoldTimer (with jitter).
 *            - clear *its* comatose flag.
 *
 *      The effect is that if both connections make it to OpenSent, then only
 *      when *both* fall back to Idle will the FSM try to make any new TCP
 *      connections.
 *
 *      The IdleHoldTimer increases up to 120 seconds.  In the worst case, the
 *      far end repeatedly makes outgoing connection attempts, and immediately
 *      drops them.  In which case, the IdleHoldTimer grows, and the disruption
 *      reduces to once every 90-120 seconds !
 *
 *   2) attempting to establish a BGP session: OpenSent/OpenConfirm
 *
 *      If something goes wrong, or the other end closes the connection (with
 *      or without notification) the FSM will loop back to Idle state.  Also,
 *      when collision resolution closes one connection it too loops back to
 *      Idle (see above).
 *
 *      Both connections may reach OpenSent.  Only one at once can reach
 *      OpenConfirm -- collision resolution sees to that.
 *
 *      Note that while a NOTIFICATION is being sent the connection stays
 *      in OpenSent/OpenConfirm state.
 *
 *   3) BGP session established
 *
 *      If something goes wrong, or the other end closes the connection
 *      (with or without notification) will stop the session.
 *
 * When things do go wrong, one of the following events is generated:
 *
 *   a. BGP_Stop -- general exception
 *
 *      The function bgp_fsm_exception() sets the reason for the exception and
 *      raises an BGP_Stop event.
 *
 *      Within the FSM, bgp_fsm_set_exception() sets the reason for the
 *      exception and .....
 *      connections.  These may be used, for example, to signal that an UPDATE
 *      message is invalid.
 *
 *      See below for further discussion of BGP_Stop.
 *
 *      (The FSM itself uses bgp_fsm_set_stopping() before moving to
 *       Stopping state.)
 *
 *   b. TCP_connection_closed ("soft" error)
 *
 *      A read or write operation finds that the connection has been closed.
 *
 *      This is raised when a read operation returns 0 bytes.
 *
 *      Is also raised when read or write see the errors:
 *
 *        ECONNRESET, ENETDOWN, ENETUNREACH, EPIPE or ETIMEDOUT
 *
 *      Other errors are reported as TCP_fatal_error.
 *
 *      The function bgp_fsm_io_error() is used by read and write operations to
 *      signal an error -- it decides which event to generate.  (Error == 0 is
 *      used to signal a read operation that has returned 0.)
 *
 *   c. TCP_connection_open_failed ("soft" error)
 *
 *      A connect() operation has failed:
 *
 *        ECONNREFUSED, ECONNRESET, EHOSTUNREACH or ETIMEDOUT
 *
 *      Other errors are reported as TCP_fatal_error.
 *
 *      The function bgp_fsm_connect_completed() decides what event to generate.
 *      (It will generate TCP_connection_open if there is no error.)
 *
 *      All errors that accept() may raise are fatal.
 *
 *   d. TCP_fatal_error ("hard" error)
 *
 *      Raised by unexpected errors in connect/accept/read/write
 *
 *      The function bgp_fsm_io_fatal_error() will generate a TCP_fatal_error.
 *
 *  Things may also go wrong withing the FSM.
 *
 *  The procedure for dealing with an exception
 *
 *------------------------------------------------------------------------------
 * FSM errors
 *
 * Invalid events: if the FSM receives an event that cannot be raised in the
 * current state, it will terminate the session, sending an FSM Error
 * NOTIFICATION (if a TCP connection is up).  See bgp_fsm_invalid().
 *
 * If the FSM receives a message type that is not expected in the current,
 * state, it will close the connection (if OpenSent or OpenConfirm) or stop
 * the session (if Established), also sending an FSM Error NOTIFICATION.
 * See bgp_fsm_error().
 *
 *------------------------------------------------------------------------------
 * Sending NOTIFICATION message
 *
 * In OpenSent, OpenConfirm and Established states may send a NOTIFICATION
 * message.
 *
 * The procedure for sending a NOTIFICATION is:
 *
 *   -- close the connection for reading and clear read buffers.
 *
 *      This ensures that no further read I/O can occur and no related events.
 *
 *      Note that anything sent from the other end is acknowledged, but
 *      quietly discarded.
 *
 *   -- purge the write buffer of all output except any partly sent message.
 *
 *      This ensures there is room in the write buffer at the very least.
 *
 *      For OpenSent and OpenConfirm states there should be zero chance of
 *      there being anything to purge, and probably no write buffer in any
 *      case.
 *
 *   -- purge any pending write messages for the connection (for Established).
 *
 *   -- set notification_pending = 1 (write pending)
 *
 *   -- write the NOTIFICATION message.
 *
 *      For Established, the message will at the very least be written to the
 *      write buffer.  For OpenSent and OpenConfirm expect it to go directly
 *      to the TCP buffer.
 *
 *   -- set HoldTimer to a waiting to clear buffer time -- say 20 secs.
 *
 *      Don't expect to need to wait at all in OpenSent/OpenConfirm states.
 *
 *   -- when the NOTIFICATION message clears the write buffer, that will
 *      generate a Sent_NOTIFICATION_message event.
 *
 * After sending the NOTIFICATION, OpenSent & OpenConfirm stay in their
 * respective states.  Established goes to Stopping State.
 *
 * When the Sent_NOTIFICATION_message event occurs, set the HoldTimer to
 * a "courtesy" time of 5 seconds.  Remain in the current state.
 *
 * During the "courtesy" time the socket will continue to acknowledge, but
 * discard input.  In the case of Collision Resolution this gives a little time
 * for the other end to send its NOTIFICATION message.  In all cases, it gives
 * a little time before the connection is slammed shut.
 *
 * When the HoldTimer expires close the connection completely (whether or not
 * the NOTIFICATION has cleared the write buffer).
 *
 *------------------------------------------------------------------------------
 * Communication with the Routeing Engine
 *
 * The FSM sends the following messages to the Routeing Engine:
 *
 *   * bgp_session_event messages
 *
 *     These keep the Routeing Engine up to date with the progress and state of
 *     the FSM.
 *
 *     In particular, these event messages tell the Routeing Engine when the
 *     session enters and leaves sEstablished -- which is what really matters
 *     to it !
 *
 *   * bgp_session_update
 *
 *     Each time an update message arrives from the peer, it is forwarded.
 *
 *     TODO: flow control for incoming updates ??
 *
 * Three things bring the FSM to a dead stop, and stop the session:
 *
 *   1) administrative Stop -- ie the Routeing Engine disabling the session.
 *
 *   2) invalid events -- which are assumed to be bugs, really.
 *
 *   3) anything that stops the session while in Established state.
 *
 * This means that the FSM will plough on trying to establish connections with
 * configured peers, even in circumstances when the likelihood of success
 * appears slim to vanishing.  However, the Routeing Engine and the operator
 * are responsible for the decision to start and to stop trying to connect.
 */

/*==============================================================================
 * Enable the given session -- which must be newly initialised.
 *
 * This is the first step in the FSM, and the connection advances to Idle.
 *
 * Returns in something of a hurry if not enabled for connect() or for accept().
 *
 * NB: requires the session LOCKED
 */
extern void
bgp_fsm_enable_session(bgp_session session)
{
  bgp_connection connection ;

  /* Proceed instantly to a dead stop if neither connect nor listen !   */
  if (!(session->connect || session->listen))
    {
      bgp_session_event(session, bgp_session_eInvalid, NULL, 0, 0, 1) ;
      return ;
    } ;

  /* Primary connection -- if connect allowed
   *
   * NB: the start event for the primary connection is guaranteed to succeed,
   *     and nothing further will happen until the initial IdleHoldTimer
   *     expires -- always has a small, non-zero time.
   *
   *     This ensures that the secondary connection can be started before
   *     there's any change of the session being torn down !!
   */
  if (session->connect)
    {
      connection = bgp_connection_init_new(NULL, session,
                                                       bgp_connection_primary) ;
      bgp_fsm_event(connection, bgp_fsm_BGP_Start) ;
    } ;

  /* Secondary connection -- if listen allowed
   */
  if (session->listen)
    {
      connection = bgp_connection_init_new(NULL, session,
                                                     bgp_connection_secondary) ;
      bgp_fsm_event(connection, bgp_fsm_BGP_Start) ;
    } ;
} ;

 /*=============================================================================
 * Raising exceptions.
 *
 * Before generating a BGP_Stop event the cause of the stop MUST be set for
 * the connection.
 *
 * In Established state any BGP_Stop closes the connection and stops the
 * session -- sending a NOTIFICATION.
 *
 * In other states, the cause affects the outcome:
 *
 *   * bgp_stopped_admin     -- send NOTIFICATION to all connections
 *                              go to Stopping state and stop the session.
 *                              (once any NOTIFICATION has cleared, terminates
 *                               the each connection.)
 *
 *   * bgp_stopped_collision -- send NOTIFICATION
 *                              close connection & fall back to Idle
 *                              (can only happen in OpenSent/OpenConfirm)
 *
 *   * otherwise             -- if TCP connection up:
 *                                send NOTIFICATION
 *                                close connection & fall back to Idle
 *                              otherwise
 *                                do nothing (stay in Idle/Connect/Active)
 */

static void
bgp_fsm_throw_exception(bgp_connection connection, bgp_session_event_t except,
                      bgp_notify notification, int err, bgp_fsm_event_t event) ;

static bgp_fsm_state_t
bgp_fsm_catch(bgp_connection connection, bgp_fsm_state_t next_state) ;

/*------------------------------------------------------------------------------
 * Ultimate exception -- disable the session
 *
 * Does nothing if neither connection exists (which implies the session has
 * already been disabled, or never got off the ground).
 *
 * NB: takes responsibility for the notification structure.
 *
 * NB: requires the session LOCKED
 */
extern void
bgp_fsm_disable_session(bgp_session session, bgp_notify notification)
{
  bgp_connection connection ;

  connection = session->connections[bgp_connection_primary] ;
  if (connection == NULL)
    connection = session->connections[bgp_connection_secondary] ;

  if (connection != NULL)
    bgp_fsm_throw_exception(connection, bgp_session_eDisabled, notification, 0,
                                                             bgp_fsm_BGP_Stop) ;
  else
    bgp_notify_free(&notification) ;
} ;

/*------------------------------------------------------------------------------
 * Raise a general exception -- not I/O related.
 *
 * Note that I/O problems are signalled by bgp_fsm_io_error().
 *
 * NB: may NOT be used within the FSM.
 */
extern void
bgp_fsm_raise_exception(bgp_connection connection, bgp_session_event_t except,
                                                        bgp_notify notification)
{
  bgp_fsm_throw_exception(connection, except, notification, 0,
                                                             bgp_fsm_BGP_Stop) ;
} ;

/*------------------------------------------------------------------------------
 * Raise a discard exception for sibling.
 *
 * A connection will discard any sibling if:
 *
 *   * the session is being disabled (by the Peering Engine)
 *
 *   * an invalid event is bringing down the session
 *
 *   * it has reached Established state, and is snuffing out the sibling.
 *
 *
 *
 * NB: requires the session LOCKED
 */
static void
bgp_fsm_discard_sibling(bgp_connection sibling, bgp_notify notification)
{
  bgp_fsm_throw_exception(sibling, bgp_session_eDiscard,
                                            notification, 0, bgp_fsm_BGP_Stop) ;
} ;

/*------------------------------------------------------------------------------
 * Raise a NOTIFICATION received exception
 */
extern void
bgp_fsm_notification_exception(bgp_connection connection,
                                                        bgp_notify notification)
{
  bgp_fsm_throw_exception(connection, bgp_session_eNOM_recv, notification, 0,
                                         bgp_fsm_Receive_NOTIFICATION_message) ;
} ;

/*------------------------------------------------------------------------------
 * Raise a "fatal I/O error" exception on the given connection.
 *
 * Error to be reported as "TCP_fatal_error".
 */
extern void
bgp_fsm_io_fatal_error(bgp_connection connection, int err)
{
  plog_err (connection->log, "%s [Error] bgp IO error: %s",
            connection->host, safe_strerror(err)) ;

  bgp_fsm_throw_exception(connection, bgp_session_eTCP_error, NULL, err,
                                                      bgp_fsm_TCP_fatal_error) ;
} ;

/*------------------------------------------------------------------------------
 * Raise an "I/O error" exception on the given connection.
 *
 * This is used by read/write operations -- so not until the TCP connection
 * is up (which implies OpenSent state or later).
 *
 * It is assumed that the read/write code deals with EAGAIN/EWOULDBLOCK/EINTR
 * itself -- so only real errors are reported here.
 *
 * A read operation that returns zero is reported here as err == 0.
 *
 * The following are reported as "TCP_connection_closed":
 *
 *   0, ECONNRESET, ENETDOWN, ENETUNREACH, EPIPE or ETIMEDOUT
 *
 * All other errors are reported as "TCP_fatal_error".
 */
extern void
bgp_fsm_io_error(bgp_connection connection, int err)
{
  if (   (err == 0)
      || (err == ECONNRESET)
      || (err == ENETDOWN)
      || (err == ENETUNREACH)
      || (err == EPIPE)
      || (err == ETIMEDOUT) )
    {
      if (BGP_DEBUG(events, EVENTS))
        {
          if (err == 0)
            plog_debug(connection->log,
                       "%s [Event] BGP connection closed fd %d",
                               connection->host, qps_file_fd(&connection->qf)) ;
          else
            plog_debug(connection->log,
                       "%s [Event] BGP connection closed fd %d (%s)",
                               connection->host, qps_file_fd(&connection->qf),
                                                           safe_strerror(err)) ;
        } ;

      bgp_fsm_throw_exception(connection, bgp_session_eTCP_dropped, NULL, err,
                                                bgp_fsm_TCP_connection_closed) ;
    }
  else
    bgp_fsm_io_fatal_error(connection, err) ;
} ;

/*------------------------------------------------------------------------------
 * Signal completion of a connect() or an accept() for the given connection.
 *
 * This is used by the connect() and accept() qpselect actions.  It is also
 * used if a connect() attempt fails immediately.
 *
 * If err == 0, then all is well: copy the local and remote sockunions
 *                            and generate TCP_connection_open event
 *
 * If err is one of:
 *
 *   ECONNREFUSED, ECONNRESET, EHOSTUNREACH or ETIMEDOUT
 *
 * generate TCP_connection_open_failed event.  (accept() does not return any of
 * these errors.)
 *
 * Other errors are reported as TCP_fatal_error.
 */
extern void
bgp_fsm_connect_completed(bgp_connection connection, int err,
                                                   union sockunion* su_local,
                                                   union sockunion* su_remote)
{
  if (err == 0)
    {
      bgp_fsm_event(connection, bgp_fsm_TCP_connection_open) ;

      connection->su_local  = sockunion_dup(su_local) ;
      connection->su_remote = sockunion_dup(su_remote) ;
    }
  else if (   (err == ECONNREFUSED)
           || (err == ECONNRESET)
           || (err == EHOSTUNREACH)
           || (err == ETIMEDOUT) )
    bgp_fsm_throw_exception(connection, bgp_session_eTCP_failed, NULL, err,
                                           bgp_fsm_TCP_connection_open_failed) ;
  else
    bgp_fsm_io_fatal_error(connection, err) ;
} ;

/*------------------------------------------------------------------------------
 * Post the given exception.
 *
 * Forget the notification if not OpenSent/OpenConfirm/Established.  Cannot
 * send notification in any other state -- nor receive one.
 *
 * NB: takes responsibility for the notification structure.
 */
static void
bgp_fsm_post_exception(bgp_connection connection, bgp_session_event_t except,
                        bgp_notify notification, int err)
{
  connection->except       = except ;

  if (   (connection->state != bgp_fsm_OpenSent)
      && (connection->state != bgp_fsm_OpenConfirm)
      && (connection->state != bgp_fsm_Established) )
    bgp_notify_free(&notification) ;

  bgp_notify_set(&connection->notification, notification) ;

  connection->err          = err ;
} ;

/*------------------------------------------------------------------------------
 * Post the given exception and raise the given event.
 *
 * NB: takes responsibility for the notification structure.
 */
static void
bgp_fsm_throw_exception(bgp_connection connection, bgp_session_event_t except,
                        bgp_notify notification, int err, bgp_fsm_event_t event)
{
  bgp_fsm_post_exception(connection, except,notification, err) ;
  bgp_fsm_event(connection, event) ;
} ;

/*------------------------------------------------------------------------------
 * Post and immediately catch a non-I/O exception.
 *
 * For use WITHIN the FSM.
 *
 * NB: requires the session LOCKED
 */
static bgp_fsm_state_t
bgp_fsm_post_catch(bgp_connection connection, bgp_session_event_t except,
                            bgp_notify notification, bgp_fsm_state_t next_state)
{
  bgp_fsm_post_exception(connection, except, notification, 0) ;
  return bgp_fsm_catch(connection, next_state) ;
} ;

/*==============================================================================
 * For debug...
 */
#define BGP_FSM_DEBUG(connection, message) \
  if (BGP_DEBUG (fsm, FSM)) \
    plog_debug (connection->log, "%s [FSM] " message, connection->host)

/*==============================================================================
 * The FSM table
 */

#define bgp_fsm_action(FUNCNAME) \
  bgp_fsm_state_t FUNCNAME(bgp_connection connection, \
                    bgp_fsm_state_t next_state, bgp_fsm_event_t event)

typedef bgp_fsm_action(bgp_fsm_action_func) ;

struct bgp_fsm
{
  bgp_fsm_action_func*  action ;
  bgp_fsm_state_t       next_state ;
} ;

static bgp_fsm_action(bgp_fsm_null) ;
static bgp_fsm_action(bgp_fsm_enter) ;
static bgp_fsm_action(bgp_fsm_stop) ;
static bgp_fsm_action(bgp_fsm_invalid) ;
static bgp_fsm_action(bgp_fsm_start) ;
static bgp_fsm_action(bgp_fsm_send_open) ;
static bgp_fsm_action(bgp_fsm_failed) ;
static bgp_fsm_action(bgp_fsm_fatal) ;
static bgp_fsm_action(bgp_fsm_retry) ;
static bgp_fsm_action(bgp_fsm_closed) ;
static bgp_fsm_action(bgp_fsm_expire) ;
static bgp_fsm_action(bgp_fsm_recv_open) ;
static bgp_fsm_action(bgp_fsm_error) ;
static bgp_fsm_action(bgp_fsm_recv_nom) ;
static bgp_fsm_action(bgp_fsm_sent_nom) ;
static bgp_fsm_action(bgp_fsm_send_kal) ;
static bgp_fsm_action(bgp_fsm_establish) ;
static bgp_fsm_action(bgp_fsm_recv_kal) ;
static bgp_fsm_action(bgp_fsm_update) ;
static bgp_fsm_action(bgp_fsm_exit) ;

/*------------------------------------------------------------------------------
 *  Finite State Machine events
 *
 *    0. null_event
 *
 *       Do nothing.  As quietly as possible.
 *
 *       Never generated, so should not be seen !
 *
 *    1. BGP_Start
 *
 *         a. in Initial state  (-> Idle)
 *
 *            raised immediately after creating the connection.
 *
 *         b. in Idle state
 *
 *            raised on expiry of IdleHoldTime.
 *
 *            primary connection:   proceed to Connect
 *
 *            secondary connection: proceed to Accept
 *
 *       Cannot happen at any other time.
 *
 *    2. BGP_Stop
 *
 *         a. in all states:
 *
 *              -- from Routeing Engine -- at any time.
 *
 *              -- internally in the event of collision resolution.
 *
 *              -- internally, in the event of some protocol error -- once
 *                 connection is up and packets are being transferred.
 *
 *       See above for further discussion.
 *
 *    3. TCP_connection_open
 *
 *         a. primary connection:   in Connect state  (-> OpenSent)
 *
 *            raised when a connect() connection succeeds
 *
 *         b. secondary connection: in Active state  (-> OpenSent)
 *
 *            raised when an accept() connection is accepted.
 *
 *       Cannot happen at any other time.
 *
 *    4. TCP_connection_closed
 *
 *       Raised by "EOF" on read or by EPIPE and some other errors.
 *
 *         a. in OpenSent and OpenConfirm states
 *
 *            This may be because the the other end has detected a collision.
 *            It may be because the other end is being vexatious.
 *
 *            Fall back to Idle.
 *
 *         b. and Established state
 *
 *            Stop the session.
 *
 *       NB: any errors generated when the OPEN message is sent (on exit from
 *           Connect or Active states) are not delivered until has entered
 *           OpenSent state.
 *
 *       Cannot happen at any other time.
 *
 *    5. TCP_connection_open_failed ("soft" error)
 *
 *         a. in Connect or Active states
 *
 *            Close the connection.  For Active state, disable accept.
 *
 *            Stay in Connect/Active (until ConnectRetryTimer expires).
 *
 *       Cannot happen at any other time.
 *
 *    6. TCP_fatal_error ("hard" error)
 *
 *         a. in Connect or Active states
 *
 *            Close the connection.  For Active state, disable accept.
 *
 *            Stay in Connect/Active (until ConnectRetryTimer expires).
 *
 *         b. in OpenSent/OpenConfirm states
 *
 *            Close the connection.
 *
 *            Fall back to Idle.
 *
 *         c. in Established state
 *
 *            Close the connection and the session.
 *
 *            Go to Stopping state.
 *
 *         d. in Stopping state.
 *
 *            Close the connection.
 *
 *       Cannot happen at any other time (ie Idle).
 *
 *    7. ConnectRetry_timer_expired
 *
 *         a. in either Connect or Active states ONLY.
 *
 *            Time to give up current connection attempt(s), and start trying
 *            to connect all over again.
 *
 *       Cannot happen at any other time.
 *
 *    8. Hold_Timer_expired
 *
 *         a. in OpenSent state
 *
 *            Time to give up waiting for an OPEN (or NOTIFICATION) from the
 *            other end.  For this wait the RFC recommends a "large" value for
 *            the hold time -- and suggests 4 minutes.
 *
 *            Or, if the connection was stopped by the collision resolution
 *            process, time to close the connection.
 *
 *            Close the connection.  Fall back to Idle.
 *
 *         b. in OpenConfirm state
 *
 *            Time to give up waiting for a KEEPALIVE to confirm the connection.
 *            For this wait the hold time used is that negotiated in the OPEN
 *            messages that have been exchanged.
 *
 *            Or, if the connection was stopped by the collision resolution
 *            process, time to close the connection.
 *
 *            Close the connection.  Fall back to Idle.
 *
 *         c. in Established state
 *
 *            The session has failed.  Stop.
 *
 *            In this state the hold time used is that negotiated in the OPEN
 *            messages that have been exchanged.
 *
 *         d. in Stopping state
 *
 *            Time to give up trying to send NOTIFICATION and terminate the
 *            connection.
 *
 *       Cannot happen at any other time.
 *
 *    9. KeepAlive_timer_expired
 *
 *         a. in OpenConfirm and Established states
 *
 *            Time to send a KEEPALIVE message.
 *
 *            In these states the keepalive time used is that which follows
 *            from the hold time negotiated in the OPEN messages that have been
 *            exchanged.
 *
 *       Cannot happen at any other time.
 *
 *   10. Receive_OPEN_message
 *
 *       Generated by read action.
 *
 *         a. in OpenSent state -- the expected response
 *
 *            Proceed (via collision resolution) to OpenConfirm or Stopping.
 *
 *         b. in OpenConfirm state -- FSM error
 *
 *            Send NOTIFICATION.  Fall back to Idle.
 *
 *         c. in Established state -- FSM error
 *
 *            Send NOTIFICATION.  Terminate session.
 *
 *       Cannot happen at any other time (connection not up or read closed).
 *
 *   11. Receive_KEEPALIVE_message
 *
 *       Generated by read action.
 *
 *         a. in OpenSent state -- FSM error
 *
 *            Send NOTIFICATION.  Fall back to Idle.
 *
 *         b. in OpenConfirm state -- the expected response
 *
 *         c. in Established state -- expected
 *
 *       Cannot happen at any other time (connection not up or read closed).
 *
 *   12. Receive_UPDATE_message
 *
 *       Generated by read action.
 *
 *         a. in OpenSent and OpenConfirm states -- FSM error
 *
 *            Send NOTIFICATION.  Fall back to Idle.
 *
 *         b. in Established state -- expected
 *
 *       Cannot happen at any other time (connection not up or read closed).
 *
 *   13. Receive_NOTIFICATION_message
 *
 *       Generated by read action.
 *
 *         a. in OpenSent, OpenConfirm and Established states -- give up
 *            on the session.
 *
 *         a. in OpenSent, OpenConfirm and Established states -- give up
 *            on the session.
 *
 *       Cannot happen at any other time (connection not up or read closed).
 *
 *   14. Sent_NOTIFICATION_message
 *
 *       Generated by write action when completed sending the message.
 *
 *         a. in Stopping state -- the desired outcome
 *
 *            Terminate the connection.
 *
 *       Cannot happen at any other time.
 */

/*------------------------------------------------------------------------------
 *  Finite State Machine Table
 */

static const struct bgp_fsm
bgp_fsm[bgp_fsm_last_state + 1][bgp_fsm_last_event + 1] =
{
  {
    /* bgp_fsm_Initial: initialised in this state...............................
     *
     * Expect only a BGP_Start event, which arms the IdleHoldTimer and advances
     * to the Idle state.
     *
     * Could (just) get a bgp_fsm_Stop if other connection stops immediately !
     *
     * A connection should be in this state for a brief period between being
     * initialised and set going.
     *
     * All other events (other than null) are invalid (should not happen).
     */
    {bgp_fsm_null,      bgp_fsm_Initial},     /* null event                   */
    {bgp_fsm_enter,     bgp_fsm_Idle},        /* BGP_Start                    */
    {bgp_fsm_stop,      bgp_fsm_Initial},     /* BGP_Stop                     */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* TCP_connection_open          */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* TCP_connection_closed        */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* TCP_connection_open_failed   */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* TCP_fatal_error              */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* ConnectRetry_timer_expired   */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* Hold_Timer_expired           */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* KeepAlive_timer_expired      */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* Receive_OPEN_message         */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* Receive_KEEPALIVE_message    */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* Receive_UPDATE_message       */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* Receive_NOTIFICATION_message */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* Sent NOTIFICATION message    */
  },
  {
    /* bgp_fsm_Idle: waiting for IdleHoldTimer..................................
     *
     * When a session is enabled both its connections start in this state.
     * (Noting that an accept() only session starts only the secondary
     * connection and a connect() only session starts only the primary.)
     *
     * While in this state is waiting for the IdleHoldTimer to expire.  This
     * timer becomes longer if the peer misbehaves.
     *
     * If a connection stops at OpenState or OpenConfirm, may loop back through
     * Idle, with an increased IdleHoldTimer.
     *
     * In Idle state the connection is dormant.  (While the secondary is Idle,
     * no connections will be accepted.)
     *
     * If the peer keeps making or accepting TCP connections, and then dropping
     * them, then the IdleHoldTimer will grow to slow down the rate of vexatious
     * connections.
     *
     * When a connection falls back to Idle it will have been closed.
     *
     * The expected events are:
     *
     *   * BGP_Start -- generated by IdleHoldTimer expired
     *
     *     For primary connection:
     *
     *       Causes a connect() to be attempted.
     *
     *         * Connect state   -- if connect() OK, or failed "soft"
     *
     *         * Stopping state  -- if connect() failed "hard"
     *
     *           Bring connection and session to a dead stop.
     *
     *     For secondary connection:
     *
     *       Enables session->accept, and goes to "Active" state.
     *
     *     Note that bgp_fsm_start() decides on the appropriate next state.
     *
     *   * BGP_Stop -- for whatever reason
     *
     * All other events (other than null) are invalid (should not happen).
     */
    {bgp_fsm_null,      bgp_fsm_Idle},        /* null event                   */
    {bgp_fsm_start,     bgp_fsm_Connect},     /* BGP_Start                    */
    {bgp_fsm_stop,      bgp_fsm_Idle},        /* BGP_Stop                     */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* TCP_connection_open          */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* TCP_connection_closed        */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* TCP_connection_open_failed   */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* TCP_fatal_error              */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* ConnectRetry_timer_expired   */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* Hold_Timer_expired           */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* KeepAlive_timer_expired      */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* Receive_OPEN_message         */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* Receive_KEEPALIVE_message    */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* Receive_UPDATE_message       */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* Receive_NOTIFICATION_message */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* Sent NOTIFICATION message    */
  },
  {
    /* bgp_fsm_Connect: waiting for connect (and listen)........................
     *
     * Only the primary connection can be in this state.
     *
     * While in this state is waiting for connection to succeed or fail, or for
     * the ConnectRetryTimer to expire.
     *
     * The expected events are:
     *
     *   * TCP_connection_open
     *
     *     Send BGP OPEN message, arm the HoldTimer ("large" value) and advance
     *     to OpenSent.
     *
     *   * TCP_connection_open_fail ("soft" error)
     *
     *     Shut down the connection.  Stay in Connect state.
     *
     *     The ConnectRetryTimer is left running.
     *
     *   * TCP_fatal_error ("hard" error)
     *
     *     Bring connection and session to a dead stop.
     *
     *   * ConnectRetry_timer_expired
     *
     *     Shut down the connection.  Retry opening a connection.  Stay in
     *     Connect state.  Refresh the ConnectRetryTimer.
     *
     *   * BGP_Stop -- for whatever reason
     *
     * All other events (other than null) are invalid (should not happen).
     */
    {bgp_fsm_null,      bgp_fsm_Connect},     /* null event                   */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* BGP_Start                    */
    {bgp_fsm_stop,      bgp_fsm_Connect},     /* BGP_Stop                     */
    {bgp_fsm_send_open, bgp_fsm_OpenSent},    /* TCP_connection_open          */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* TCP_connection_closed        */
    {bgp_fsm_failed,    bgp_fsm_Connect},     /* TCP_connection_open_failed   */
    {bgp_fsm_fatal,     bgp_fsm_Connect},     /* TCP_fatal_error              */
    {bgp_fsm_retry,     bgp_fsm_Connect},     /* ConnectRetry_timer_expired   */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* Hold_Timer_expired           */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* KeepAlive_timer_expired      */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* Receive_OPEN_message         */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* Receive_KEEPALIVE_message    */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* Receive_UPDATE_message       */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* Receive_NOTIFICATION_message */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* Sent NOTIFICATION message    */
  },
  {
    /* bgp_fsm_Active: waiting for listen (only)................................
     *
     * Only the secondary connection can be in this state.
     *
     * While in this state is waiting for an incoming connection to succeed or
     * for the ConnectRetryTimer to expire.
     *
     * The expected events are:
     *
     *   * TCP_connection_open
     *
     *     Send BGP OPEN message, arm the HoldTimer ("large" value) and advance
     *     to OpenSent.
     *
     *   * TCP_connection_open_fail ("soft" error)
     *
     *     Shut down the connection.  Stay in Connect state.
     *
     *     The ConnectRetryTimer is left running.
     *
     *   * TCP_fatal_error
     *
     *     Bring connection and session to a dead stop.
     *
     *   * ConnectRetry_timer_expired
     *
     *     Stay in Active state.  Refresh the ConnectRetryTimer.
     *
     *   * BGP_Stop -- for whatever reason
     *
     * All other events (other than null) are invalid (should not happen).
     */
    {bgp_fsm_null,      bgp_fsm_Active},      /* null event                   */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* BGP_Start                    */
    {bgp_fsm_stop,      bgp_fsm_Active},      /* BGP_Stop                     */
    {bgp_fsm_send_open, bgp_fsm_OpenSent},    /* TCP_connection_open          */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* TCP_connection_closed        */
    {bgp_fsm_failed,    bgp_fsm_Active},      /* TCP_connection_open_failed   */
    {bgp_fsm_fatal,     bgp_fsm_Active},      /* TCP_fatal_error              */
    {bgp_fsm_retry,     bgp_fsm_Active},      /* ConnectRetry_timer_expired   */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* Hold_Timer_expired           */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* KeepAlive_timer_expired      */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* Receive_OPEN_message         */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* Receive_KEEPALIVE_message    */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* Receive_UPDATE_message       */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* Receive_NOTIFICATION_message */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* Sent NOTIFICATION message    */
  },
  {
    /* bgp_fsm_OpenSent: waiting for Open from the other end....................
     *
     * Both primary and secondary connections can be in this state.
     *
     * While in this state is waiting for a BGP OPEN to arrive or for the
     * HoldTimer ("large" value) to expire.
     *
     * The expected events are:
     *
     *   * Receive_OPEN_message
     *
     *     This means has received a satisfactory BGP OPEN from the other end,
     *     so the session is very nearly up.
     *
     *     If there is another connection, and it is in OpenConfirm state,
     *     then must now choose between the two -- terminating one or the
     *     other with a "Connection Collision Resolution" NOTIFICATION message.
     *
     *     If proceeding, send a BGP KEEPALIVE message (effectively ACK), arm
     *     HoldTimer and KeepliveTimer (as per negotiated values) and advance
     *     to OpenConfirm state.
     *
     *   * Receive_UPDATE_message
     *
     *     FSM error -- bring connection to a dead stop.
     *
     *   * Receive_KEEPALIVE_message
     *
     *     FSM error -- bring connection to a dead stop.
     *
     *   * Receive_NOTIFICATION_message
     *
     *     Bring connection to a dead stop.
     *
     *   * TCP_connection_closed
     *
     *     Close connection,
     *
     *   * TCP_fatal_error
     *
     *     Bring connection and session to a dead stop.
     *
     *   * Hold_Timer_expired
     *
     *     If primary, promote the secondary.  If no secondary...
     *
     *   * BGP_Stop -- for whatever reason
     *
     * All other events (other than null) are invalid (should not happen).
     */
    {bgp_fsm_null,      bgp_fsm_OpenSent},    /* null event                   */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* BGP_Start                    */
    {bgp_fsm_stop,      bgp_fsm_Idle},        /* BGP_Stop                     */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* TCP_connection_open          */
    {bgp_fsm_closed,    bgp_fsm_Idle},        /* TCP_connection_closed        */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* TCP_connection_open_failed   */
    {bgp_fsm_fatal,     bgp_fsm_Idle},        /* TCP_fatal_error              */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* ConnectRetry_timer_expired   */
    {bgp_fsm_expire,    bgp_fsm_Idle},        /* Hold_Timer_expired           */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* KeepAlive_timer_expired      */
    {bgp_fsm_recv_open, bgp_fsm_OpenConfirm}, /* Receive_OPEN_message         */
    {bgp_fsm_error,     bgp_fsm_OpenSent},    /* Receive_KEEPALIVE_message    */
    {bgp_fsm_error,     bgp_fsm_OpenSent},    /* Receive_UPDATE_message       */
    {bgp_fsm_recv_nom,  bgp_fsm_Idle},        /* Receive_NOTIFICATION_message */
    {bgp_fsm_sent_nom,  bgp_fsm_OpenSent},    /* Sent NOTIFICATION message    */
  },
  {
    /* bgp_fsm_OpenConfirm: Opens sent and received, waiting for KeepAlive......
     *
     * Only one of the two connections can reach this state.
     *
     * While in this state is waiting for a BGP KEEPALIVE to arrive or for the
     * HoldTimer to expire, or for the KeepaliveTimer to prompt sending of
     * another KEEPALIVE message.
     *
     * The expected events are:
     *
     *   * Receive_KEEPALIVE_message
     *
     *     This means that the other end is acknowledging the OPEN, and the
     *     session is now Established.
     *
     *     If there is another connection, now is the time to kill it off.
     *
     *     This connection becomes the primary and only connection.
     *
     *     Arm HoldTimer and KeepliveTimer (as per negotiated values) and
     *     advance to Established state.
     *
     *     Pass a session established message to the Routeing Engine, complete
     *     with the bgp_open_state for the successful connection.
     *
     *   * Receive_OPEN_message
     *
     *     FSM error -- bring connection to a dead stop.
     *
     *     If primary, promote the secondary.  If no secondary...
     *
     *   * Receive_UPDATE_message
     *
     *     FSM error -- bring connection to a dead stop.
     *
     *     If primary, promote the secondary.  If no secondary...
     *
     *   * Receive_NOTIFICATION_message
     *
     *     Bring connection to a dead stop.
     *
     *     If primary, promote the secondary.  If no secondary...
     *
     *   * TCP_connection_closed
     *
     *     If primary, promote the secondary.  If no secondary...
     *
     *   * TCP_fatal_error
     *
     *     Bring connection and session to a dead stop.
     *
     *   * KeepAlive_Timer_expired
     *
     *     Send KEEPALIVE message and recharge KeepaliveTimer.
     *
     *   * Hold_Timer_expired
     *
     *     If primary, promote the secondary.  If no secondary...
     *
     *   * BGP_Stop -- for whatever reason
     *
     * All other events (other than null) are invalid (should not happen).
     */
    {bgp_fsm_null,      bgp_fsm_OpenConfirm}, /* null event                   */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* BGP_Start                    */
    {bgp_fsm_stop,      bgp_fsm_Idle},        /* BGP_Stop                     */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* TCP_connection_open          */
    {bgp_fsm_closed,    bgp_fsm_Idle},        /* TCP_connection_closed        */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* TCP_connection_open_failed   */
    {bgp_fsm_fatal,     bgp_fsm_Idle},        /* TCP_fatal_error              */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* ConnectRetry_timer_expired   */
    {bgp_fsm_expire,    bgp_fsm_Idle},        /* Hold_Timer_expired           */
    {bgp_fsm_send_kal,  bgp_fsm_OpenConfirm}, /* KeepAlive_timer_expired      */
    {bgp_fsm_error,     bgp_fsm_OpenConfirm}, /* Receive_OPEN_message         */
    {bgp_fsm_establish, bgp_fsm_Established}, /* Receive_KEEPALIVE_message    */
    {bgp_fsm_error,     bgp_fsm_OpenConfirm}, /* Receive_UPDATE_message       */
    {bgp_fsm_recv_nom,  bgp_fsm_Idle},        /* Receive_NOTIFICATION_message */
    {bgp_fsm_sent_nom,  bgp_fsm_OpenConfirm}, /* Sent NOTIFICATION message    */
  },
  {
    /* bgp_fsm_Established: session is up and running...........................
     *
     * Only the primary connection exists in this state.
     *
     * While in this state is waiting for a BGP UPDATE (or KEEPALIVE) messages
     * to arrive or for the HoldTimer to expire, or for the KeepaliveTimer to
     * prompt sending of another KEEPALIVE message.
     *
     * The expected events are:
     *
     *   * Receive_OPEN_message
     *
     *     FSM error -- bring connection and session to a dead stop.
     *
     *   * Receive_UPDATE_message
     *
     *     Restart the HoldTimer.
     *
     *   * Receive_KEEPALIVE_message
     *
     *     Restart the HoldTimer.
     *
     *   * Receive_NOTIFICATION_message
     *
     *     Bring connection and session to a dead stop.
     *
     *   * TCP_connection_closed
     *
     *     Bring connection and session to a dead stop.
     *
     *   * TCP_fatal_error
     *
     *     Bring connection and session to a dead stop.
     *
     *   * KeepAlive_Timer_expired
     *
     *     Send KEEPALIVE message and recharge KeepaliveTimer.
     *
     *   * Hold_Timer_expired
     *
     *     If primary, promote the secondary.  If no secondary...
     *
     *   * BGP_Stop -- for whatever reason
     *
     * All other events (other than null) are invalid (should not happen).
     */
    {bgp_fsm_null,      bgp_fsm_Established}, /* null event                   */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* BGP_Start                    */
    {bgp_fsm_stop,      bgp_fsm_Stopping},    /* BGP_Stop                     */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* TCP_connection_open          */
    {bgp_fsm_closed,    bgp_fsm_Stopping},    /* TCP_connection_closed        */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* TCP_connection_open_failed   */
    {bgp_fsm_fatal,     bgp_fsm_Stopping},    /* TCP_fatal_error              */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* ConnectRetry_timer_expired   */
    {bgp_fsm_expire,    bgp_fsm_Stopping},    /* Hold_Timer_expired           */
    {bgp_fsm_send_kal,  bgp_fsm_Established}, /* KeepAlive_timer_expired      */
    {bgp_fsm_error,     bgp_fsm_Stopping},    /* Receive_OPEN_message         */
    {bgp_fsm_recv_kal,  bgp_fsm_Established}, /* Receive_KEEPALIVE_message    */
    {bgp_fsm_update,    bgp_fsm_Established}, /* Receive_UPDATE_message       */
    {bgp_fsm_recv_nom,  bgp_fsm_Stopping},    /* Receive_NOTIFICATION_message */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* Sent NOTIFICATION message    */
  },
  {
    /* bgp_fsm_Stopping: waiting (briefly) to send Notification.................
     *
     * Before a connection is sent to Stopping state the reasons for stopping
     * are set.  (See bgp_fsm_set_stopping.)
     *
     * There are three ways to arrive in Stopping state:
     *
     *   a) administrative Stop -- that is, the Routeing Engine is stopping the
     *      session.
     *
     *      Both connections must be stopped.
     *
     *   b) the sibling has reached Established state and is snuffing out
     *      its rival.
     *
     *      Only the current connection must be stopped.
     *
     *   c) the session was Established, but is now stopping.
     *
     *      There is only one connection, and that must be stopped.
     *
     * Before the transition to Stopping state,
     *
     * The complication is the possible need to send a NOTIFICATION message
     * before closing the connection.
     *
     * Once a connection has reached Established state, the TCP write buffers
     * may be full, so it may not be possible immediately to send the
     * NOTIFICATION.  Note that stopping from Established state is always
     * stop-dead.
     *
     * In other states there should be plenty of room in the TCP write buffers.
     *
     * On entry to Stopping:
     *
     *   1) if this is stop-dead -- unlink self from session.
     *
     *      NB: this clears the pointer from session to connection.
     *
     *          ....
     *
     *   2) if there is a NOTIFICATION message (notification_pending):
     *
     *        * close the connection for reading and purge read buffers
     *        * purge the write buffering and any pending writes
     *        * stop all timers
     *        * send the NOTIFICATION
     *
     *      if the NOTIFICATION immediately clears the buffers (or fails),
     *      clear the notification_pending flag.
     *
     *   3) if the notification_pending flag is still set:
     *
     *        * for stop-idle set a short time-out (5 seconds)
     *        * for stop-dead set a longer time-out (30 seconds)
     *
     *      stays in Stopping state, waiting for NOTIFICATION to be sent, or
     *      to fail, or for the timeout.
     *
     *      (Should not really need the time-out for stop-idle, but seems
     *       neater than crash closing the connection.)
     *
     *      While in Stopping state, any further event will clear the
     *      notification-pending flag.
     *
     * When the notification-pending flag is not set:
     *
     *   * close the connection
     *   * purge all buffering
     *   * stop all timers
     *
     *   * for stop-idle: proceed to Idle state





     * In this state the connection is no longer associated with a session.
     *
     * This state exists only to allow the TCP output buffer to drain
     * sufficiently to allow the tail end of one BGP message to be sent,
     * followed by a NOTIFICATION message.
     *
     * When entering this state, if there is no NOTIFICATION to send, then
     * will terminate the session.
     *
     * While in this state is waiting for the NOTIFICATION message to have been
     * sent, or for the HoldTimer to expire (does not wait indefinitely).
     *
     * The expected events are:
     *
     *   * Sent NOTIFICATION message
     *   * Hold_Timer_expired
     *   * TCP_fatal_error
     *   * TCP_connection_closed
     *
     *     Clear NOTIFICATION pending, so connection will then be terminated.
     *
     * All other events (other than null) are invalid (should not happen).
     */
    {bgp_fsm_null,      bgp_fsm_Stopping},    /* null event                   */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* BGP_Start                    */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* BGP_Stop                     */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* TCP_connection_open          */
    {bgp_fsm_exit,      bgp_fsm_Stopping},    /* TCP_connection_closed        */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* TCP_connection_open_failed   */
    {bgp_fsm_exit,      bgp_fsm_Stopping},    /* TCP_fatal_error              */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* ConnectRetry_timer_expired   */
    {bgp_fsm_exit,      bgp_fsm_Stopping},    /* Hold_Timer_expired           */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* KeepAlive_timer_expired      */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* Receive_OPEN_message         */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* Receive_KEEPALIVE_message    */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* Receive_UPDATE_message       */
    {bgp_fsm_invalid,   bgp_fsm_Stopping},    /* Receive_NOTIFICATION_message */
    {bgp_fsm_sent_nom,  bgp_fsm_Stopping},    /* Sent NOTIFICATION message    */
  },
} ;

static const char *bgp_event_str[] =
{
  "NULL",
  "BGP_Start",
  "BGP_Stop",
  "TCP_connection_open",
  "TCP_connection_closed",
  "TCP_connection_open_failed",
  "TCP_fatal_error",
  "ConnectRetry_timer_expired",
  "Hold_Timer_expired",
  "KeepAlive_timer_expired",
  "Receive_OPEN_message",
  "Receive_KEEPALIVE_message",
  "Receive_UPDATE_message",
  "Receive_NOTIFICATION_message",
  "Sent_NOTIFICATION_message",
} ;

/*==============================================================================
 * Signal FSM event.
 */

static void
bgp_fsm_state_change(bgp_connection connection, bgp_fsm_state_t new_state) ;

/*------------------------------------------------------------------------------
 * Signal event to FSM for the given connection.
 *
 *
 *
 */
extern void
bgp_fsm_event(bgp_connection connection, bgp_fsm_event_t event)
{
  bgp_session     session ;
  bgp_fsm_state_t next_state ;
  const struct bgp_fsm* fsm ;

  dassert( (event >= bgp_fsm_null_event)
        && (event <= bgp_fsm_last_event)) ;
  dassert( (connection->state >= bgp_fsm_first_state)
        && (connection->state <= bgp_fsm_last_state) ) ;

  /* Watch out for recursing through the FSM for this connection.       */
  ++connection->fsm_active ;

  if (connection->fsm_active == 2)
    {
      connection->post = event ;
      return ;
    } ;

  /* Lock the session for the convenience of the event handlers.
   *
   * NB: if the current state is Stopping, then connection is no longer
   *     attached to session -- so connection->session is NULL -- BEWARE !
   *
   *     The session lock does nothing if no session is attached.
   */
  session = connection->session ;

  if (session != NULL)
    BGP_SESSION_LOCK(session) ; /*<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<*/

  do
    {
      assert(connection->fsm_active == 1) ;

      fsm = &bgp_fsm[connection->state][event] ;
      next_state = fsm->next_state ;

      /* Call function. */
      next_state = fsm->action(connection, next_state, event) ;

      dassert( (next_state >= bgp_fsm_first_state)
            && (next_state <= bgp_fsm_last_state) ) ;

      /* If state is changed.                               */
      if (next_state != connection->state)
        {
          bgp_fsm_state_t prev_state  = connection->state ;

          /* Complete the state change                                        */
          bgp_fsm_state_change(connection, next_state) ;

          /* Log state change as required.                                    */
          if (BGP_DEBUG(fsm, FSM))
            plog_debug(connection->log,
                       "%s [FSM] %s (%s->%s)",
                         connection->host,
                         bgp_event_str[event],
                         LOOKUP (bgp_status_msg, prev_state),
                         LOOKUP (bgp_status_msg, next_state)) ;

          if (BGP_DEBUG(normal, NORMAL))
            zlog_debug ("%s on %s went from %s to %s",
                          connection->host,
                          bgp_event_str[event],
                          LOOKUP (bgp_status_msg, prev_state),
                          LOOKUP (bgp_status_msg, next_state));
        } ;

      /* Pick up post event -- if any                                   */
      event = connection->post ;
      connection->post = bgp_fsm_null_event ;

    } while (--connection->fsm_active != 0) ;

  /* If required, post session event.                                   */

  if ((connection->except != bgp_session_null_event) && (session != NULL))
    {
      /* Some exceptions are not reported to the Routeing Engine
       *
       * In particular: eDiscard and eCollision -- so the only time the
       * connection->state will be Stopping is when the session is being
       * stopped.  (eDiscard and eCollision go quietly to Stopping !)
       */
      if (connection->except <= bgp_session_max_event)
        bgp_session_event(session, connection->except,
                                   connection->notification,
                                   connection->err,
                                   connection->ordinal,
                                  (connection->state == bgp_fsm_Stopping)) ;

      /* Tidy up -- notification already cleared                        */
      connection->except = bgp_session_null_event ;
      connection->err    = 0 ;
      bgp_notify_free(&connection->notification) ;      /* if any       */
    }

  if (session != NULL)
    BGP_SESSION_UNLOCK(session) ;   /*<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<*/
} ;

/*==============================================================================
 * The BGP FSM Action Functions
 */

static void
bgp_hold_timer_set(bgp_connection connection, unsigned secs) ;

static void
bgp_hold_timer_recharge(bgp_connection connection) ;

static bgp_fsm_state_t
bgp_fsm_send_notification(bgp_connection connection,
                                                   bgp_fsm_state_t next_state) ;

/*------------------------------------------------------------------------------
 * Null action -- do nothing at all.
 */
static bgp_fsm_action(bgp_fsm_null)
{
  return next_state ;
} ;

/*------------------------------------------------------------------------------
 * Entry point to FSM.
 *
 * This is the first thing to happen to the FSM, and takes it from Initial
 * state to Idle, with IdleHoldTimer running.
 *
 * NB: the IdleHoldTimer is always a finite time.  So the start up event for
 *     the primary connection *cannot* fail.
 *
 * NB: the session is locked.
 */
static bgp_fsm_action(bgp_fsm_enter)
{
  if (connection->ordinal == bgp_connection_secondary)
    bgp_prepare_to_accept(connection) ;

  return next_state ;
} ;

/*------------------------------------------------------------------------------
 * Stop BGP Connection -- general exception event.
 *
 * An exception should have been raised, treat as invalid if not.
 *
 * If is eDisabled, set next_state == Stopping.
 * If is eDiscard,  set next_state == Stopping.
 *
 * NB: requires the session LOCKED
 */
static bgp_fsm_action(bgp_fsm_stop)
{
  if (connection->except == bgp_session_null_event)
    return bgp_fsm_invalid(connection, bgp_fsm_Stopping, event) ;

  if (   (connection->except == bgp_session_eDisabled)
      || (connection->except == bgp_session_eDiscard) )
    next_state = bgp_fsm_Stopping ;

  return bgp_fsm_catch(connection, next_state) ;
} ;

/*------------------------------------------------------------------------------
 * Invalid event -- cannot occur in current state.
 *
 * Brings down the session, sending an FSM error NOTIFICATION.
 *
 * Forces transition to Stopping state for this connection and any sibling.
 *
 * If already in Stopping state, force exit.
 *
 * NB: requires the session LOCKED
 */
static bgp_fsm_action(bgp_fsm_invalid)
{
  if (BGP_DEBUG(fsm, FSM)) \
    plog_debug(connection->log, "%s [FSM] invalid event %d in state %d",
                                   connection->host, event, connection->state) ;

  if (connection->state != bgp_fsm_Stopping)
    return bgp_fsm_post_catch(connection, bgp_session_eInvalid,
                          bgp_notify_new(BGP_NOMC_FSM, BGP_NOMS_UNSPECIFIC, 0),
                                                             bgp_fsm_Stopping) ;
  else
    return bgp_fsm_exit(connection, bgp_fsm_Stopping, event) ;
} ;

/*------------------------------------------------------------------------------
 * Start up BGP Connection
 *
 * This is used:
 *
 *   * to change from Idle to Connect or Active -- when the IdleHoldTimer
 *     expires.
 *
 *   * to loop back to Connect or Active -- when the ConnectRetryTimer expires.
 *
 * The state entered depends on whether this is the primary or secondary
 * connection.
 *
 * If this is the primary connection, then kicks a connect() into life,
 * before the state change.  Note that if that fails, then post an event to
 * be processed as soon as completes the state transition.
 *
 * If this is the secondary connection, enables the session for accept().
 *
 * NB: requires the session LOCKED
 */
static bgp_fsm_action(bgp_fsm_start)
{
  if (connection->ordinal == bgp_connection_primary)
    {
      next_state = bgp_fsm_Connect ;
      bgp_open_connect(connection) ;
    }
  else
    {
      next_state = bgp_fsm_Active ;
      bgp_connection_enable_accept(connection) ;
    } ;

  return next_state ;
} ;

/*------------------------------------------------------------------------------
 * TCP connection open has come up -- connect() or accept()
 *
 * Send BGP Open Message to peer.
 *
 * NB: requires the session LOCKED
 */
static bgp_fsm_action(bgp_fsm_send_open)
{
  char  buf_l[SU_ADDRSTRLEN] ;
  char  buf_r[SU_ADDRSTRLEN] ;
  const char* how ;

  if (BGP_DEBUG (normal, NORMAL))
    {
      if (connection->ordinal == bgp_connection_primary)
        how = "connect" ;
      else
        how = "accept" ;

      zlog_debug("%s open %s(), local address %s",
                  sockunion2str(connection->su_remote, buf_r, SU_ADDRSTRLEN),
                  how,
                  sockunion2str(connection->su_local,  buf_l, SU_ADDRSTRLEN)) ;
    } ;

  bgp_connection_read_enable(connection) ;

  bgp_msg_send_open(connection, connection->session->open_send) ;

  return next_state ;
} ;

/*------------------------------------------------------------------------------
 * TCP connection has failed to come up -- Connect/Active states.
 *
 * This is in response to TCP_connection_open_failed, which has posted the
 * exception -- so now need to deal with it.
 *
 * Close the connection -- if secondary connection, disable accept.
 *
 * Will stay in Connect/Active states.
 *
 * NB: requires the session LOCKED
 */
static bgp_fsm_action(bgp_fsm_failed)
{
  return bgp_fsm_catch(connection, next_state) ;
} ;

/*------------------------------------------------------------------------------
 * Fatal I/O error -- any state (other than Idle and Stopping).
 *
 * Close the connection (if any) -- if secondary connection, disable accept.
 *
 * This is in response to TCP_fatal_error, which has posted the
 * exception -- so now need to deal with it.
 *
 * NB: requires the session LOCKED
 */
static bgp_fsm_action(bgp_fsm_fatal)
{
  return bgp_fsm_catch(connection, next_state) ;
} ;

/*------------------------------------------------------------------------------
 * ConnectRetryTimer expired -- Connect/Active states.
 *
 * If the connection failed, the connection will have been closed.  For the
 * secondary connection accept() will have been disabled.
 *
 * For primary connection:
 *
 *   * close the attempt to connect() (if still ative)
 *   * start the connect() attempt again
 *
 * For secondary connection:
 *
 *   * re-enable accept (if has been cleared) and wait for same
 *
 * NB: requires the session LOCKED
 */
static bgp_fsm_action(bgp_fsm_retry)
{
  if (connection->ordinal == bgp_connection_primary)
    bgp_close_connect(connection) ;

  bgp_fsm_post_exception(connection, bgp_session_eRetry, NULL, 0) ;

  return bgp_fsm_start(connection, next_state, event) ;
} ;

/*------------------------------------------------------------------------------
 * TCP connection has closed -- OpenSent/OpenConfirm/Established states
 *
 * This is in response to TCP_connection_closed, which has posted the
 * exception -- so now need to deal with it.
 *
 * NB: requires the session LOCKED
 */
static bgp_fsm_action(bgp_fsm_closed)
{
  return bgp_fsm_catch(connection, next_state) ;
} ;

/*------------------------------------------------------------------------------
 * Hold timer expire -- OpenSent/OpenConfirm/Stopping
 *
 * This means either: have finished sending NOTIFICATION (end of "courtesy"
 *                    wait time)
 *
 *                or: can wait no longer for something from the other end.
 *
 * NB: requires the session LOCKED
 */
static bgp_fsm_action(bgp_fsm_expire)
{
  /* The process of sending a NOTIFICATION comes to an end here.        */
  if (connection->notification_pending)
    {
      bgp_connection_close(connection) ;

      return next_state ;
    } ;

  /* Otherwise: post and immediately catch exception.                  */
  return bgp_fsm_post_catch(connection, bgp_session_eExpired,
                     bgp_notify_new(BGP_NOMC_HOLD_EXP, BGP_NOMS_UNSPECIFIC, 0),
                                                                   next_state) ;
} ;

/*------------------------------------------------------------------------------
 * Received an acceptable OPEN Message
 *
 * The next state is expected to be OpenConfirm.
 *
 * However: this is where we do Collision Resolution.
 *
 * If the sibling connection has reached OpenConfirm before this one, then now
 * this one either closes its sibling, or itself.
 *
 * As soon as a connection reaches Established, it immediately kills off any
 * sibling -- so the farthest two connections can get is to OpenSent.
 *
 * The connection that is closed should send a Cease/Collision Resolution
 * NOTIFICATION.  The other end should do likewise.
 *
 * The connection that is closed will fall back to Idle -- so that if the
 * connection that wins the race to OpenConfirm fails there, then both will be
 * back in Idle state.
 *
 * If makes it past Collision Resolution, respond with a KEEPALIVE (to "ack"
 * the OPEN message).
 *
 * NB: requires the session LOCKED
 */
static bgp_fsm_action(bgp_fsm_recv_open)
{
  bgp_session    session = connection->session ;
  bgp_connection sibling = bgp_connection_get_sibling(connection) ;

  assert(session != NULL) ;

  /* If there is a sibling, and it is in OpenConfirm state, then now must do
   * collision resolution.
   */
  if ((sibling != NULL) && (sibling->state == bgp_fsm_OpenConfirm))
    {
      bgp_connection loser ;

      /* NB: bgp_id in open_state is in *host* order                    */
      loser = (session->open_send->bgp_id < sibling->open_recv->bgp_id)
                ? connection
                : sibling ;

      /* Set reason for stopping                                        */
      bgp_fsm_post_exception(loser, bgp_session_eCollision,
                   bgp_notify_new(BGP_NOMC_CEASE, BGP_NOMS_C_COLLISION, 0), 0) ;

      /* If self is the loser, treat this as a BGP_Stop event !         */
      /* Otherwise, issue BGP_Stop event for sibling.                   */
      if (loser == connection)
        return bgp_fsm_catch(connection, next_state) ;
      else
        bgp_fsm_event(sibling, bgp_fsm_BGP_Stop) ;
    } ;

  /* All is well: send a KEEPALIVE message to acknowledge the OPEN      */
  bgp_msg_send_keepalive(connection) ;

  /* Transition to OpenConfirm state                                    */
  return next_state ;
}

/*------------------------------------------------------------------------------
 * FSM error -- received wrong type of message !
 *
 * For example, an OPEN message while in Established state.
 *
 * For use in: OpenSent, OpenConfirm and Established states.
 *
 * Sends NOTIFICATION.
 *
 * Next state will be same as current, except for Established, when will be
 * Stopping.
 *
 * NB: requires the session LOCKED
 */
static bgp_fsm_action(bgp_fsm_error)
{
  return bgp_fsm_post_catch(connection, bgp_session_eFSM_error,
                          bgp_notify_new(BGP_NOMC_FSM, BGP_NOMS_UNSPECIFIC, 0),
                                                                   next_state) ;
} ;

/*------------------------------------------------------------------------------
 * Receive NOTIFICATION from far end -- OpenSent/OpenConfirm/Established
 *
 * This is in response to Receive_NOTIFICATION_message, which has posted the
 * exception -- so now need to deal with it.
 *
 * Next state will be Idle, except for Established, when will be Stopping.
 *
 * NB: requires the session LOCKED
 */
static bgp_fsm_action(bgp_fsm_recv_nom)
{
  return bgp_fsm_catch(connection, next_state) ;
} ;

/*------------------------------------------------------------------------------
 * Pending NOTIFICATION has cleared write buffers
 *                                          -- OpenSent/OpenConfirm/Stopping
 *
 * Set the "courtesy" HoldTimer.  Expect to stay in current state.
 *
 * NB: requires the session LOCKED
 */
static bgp_fsm_action(bgp_fsm_sent_nom)
{
  bgp_hold_timer_set(connection, 5) ;
  return next_state ;
} ;

/*------------------------------------------------------------------------------
 * Seed Keepalive to peer.
 *
 * NB: requires the session LOCKED
 */
static bgp_fsm_action(bgp_fsm_send_kal)
{
  bgp_msg_send_keepalive(connection) ;
  return next_state ;
} ;

/*------------------------------------------------------------------------------
 * Session Established !
 *
 * If there is another connection, that is now snuffed out and this connection
 * becomes the primary.
 *
 * NB: requires the session LOCKED
 */
static bgp_fsm_action(bgp_fsm_establish)
{
  bgp_session    session = connection->session ;
  bgp_connection sibling = bgp_connection_get_sibling(connection) ;

  assert(session != NULL) ;

  /* The first thing to do is to snuff out any sibling                  */
  if (sibling != NULL)
    bgp_fsm_discard_sibling(sibling,
                      bgp_notify_new(BGP_NOMC_CEASE, BGP_NOMS_C_COLLISION, 0)) ;

  /* Establish self as primary and copy state up to session             */
  bgp_connection_make_primary(connection) ;

  /* Change the session state and post event                            */
  assert(session->state == bgp_session_sEnabled) ;

  session->state = bgp_session_sEstablished ;
  bgp_fsm_post_exception(connection, bgp_session_eEstablished, NULL, 0) ;

  /* TODO: now would be a good time to withdraw the password from listener ?  */

  return next_state ;
} ;

/*------------------------------------------------------------------------------
 * Keepalive packet is received -- OpenConfirm/Established
 *
 * NB: requires the session LOCKED
 */
static bgp_fsm_action(bgp_fsm_recv_kal)
{
  /* peer count update */
//peer->keepalive_in++;

  bgp_hold_timer_recharge(connection) ;
  return next_state ;
} ;

/*------------------------------------------------------------------------------
 * Update packet is received.
 *
 * NB: requires the session LOCKED
 */
static bgp_fsm_action(bgp_fsm_update)
{
  bgp_hold_timer_recharge(connection) ;
  return next_state ;
}

/*------------------------------------------------------------------------------
 * Connection exit
 *
 * Ring down the curtain.  Connection structure will be freed by the BGP Engine.
 *
 * NB: requires the session LOCKED
 */
static bgp_fsm_action(bgp_fsm_exit)
{
  assert(connection->state == bgp_fsm_Stopping) ;

  bgp_connection_exit(connection) ;

  return bgp_fsm_Stopping ;
} ;

/*==============================================================================
 * Catching FSM Exceptions.
 *
 * Throwing/Posting Exceptions sets:
 *
 *   connection->except        )
 *   connection->err           ) which define the exception
 *   connection->notification  )
 *
 * An event has been raised, and the FSM has a (default next_state).
 *
 *  1a) notification & not eNOM_recv
 *
 *      Start sending the NOTIFICATION message.
 *
 *      NB: won't be a notification unless OpenSent/OpenConfirm/Established.
 *
 *      For OpenSent/OpenConfirm, override the next_state to stay where it is
 *      until NOTIFICATION process completes.
 *
 *      Sending NOTIFICATION closes the connection for reading.
 *
 *  1b) otherwise: close the connection.
 *
 *   2) if next state is Stopping, and not eDiscard
 *
 *      This means we bring down the session, so discard any sibling.
 *
 *      The sibling will send any notification, and proceed immediately to
 *      Stopping.
 *
 *      (The sibling will be eDiscard -- so no deadly embrace here.)
 *
 * The state machine takes care of the rest:
 *
 *   * complete entry to new state (for Stopping will cut connection loose).
 *
 *   * send message to Routeing Engine
 *
 * NB: requires the session LOCKED
 */
static bgp_fsm_state_t
bgp_fsm_catch(bgp_connection connection, bgp_fsm_state_t next_state)
{
  /* If there is a NOTIFICATION to send, now is the time to do that.
   * Otherwise, close the connection.
   */
  if (   (connection->notification != NULL)
      && (connection->except != bgp_session_eNOM_recv) )
    {
      next_state = bgp_fsm_send_notification(connection, next_state) ;
    }
  else
    bgp_connection_close(connection) ;

  /* If stopping and not eDiscard, do in any sibling                    */
  if (   (next_state == bgp_fsm_Stopping)
      && (connection->except != bgp_session_eDiscard) )
    {
      bgp_connection sibling ;

      sibling = bgp_connection_get_sibling(connection) ;  /* ... if any */

      if (sibling != NULL)
        bgp_fsm_discard_sibling(sibling,
                                     bgp_notify_dup(connection->notification)) ;
    } ;

  /* Return the (possibly adjusted) next_state                  */
  return next_state ;
} ;

/*------------------------------------------------------------------------------
 * Dispatch notification message
 *
 * Part closing the connection guarantees that can get the notification
 * message into the buffers.
 *
 * Process will generate the following events:
 *
 *   -- I/O failure of any sort
 *   -- Sent_NOTIFICATION_message
 *   -- HoldTimer expired
 *
 * When get Sent_NOTIFICATION_message, will set final "courtesy" timer, so
 * unless I/O fails, final end of process is HoldTimer expired (with
 *
 */
static bgp_fsm_state_t
bgp_fsm_send_notification(bgp_connection connection, bgp_fsm_state_t next_state)
{
  int ret ;

  /* If the next_state is not Stopping, then the sending of the notification
   * holds the FSM in the current state.  Will move forward when the
   * HoldTimer expires -- either because lost patience in getting the
   * notification away, or at the end of the "courtesy" time.
   */
  if (next_state != bgp_fsm_Stopping)
    next_state = connection->state ;

  /* Close for reading and flush write buffers.                         */
  bgp_connection_part_close(connection) ;

  /* Write the message
   *
   * If the write fails it raises a suitable event, which will now be
   * sitting waiting to be processed on the way out of the FSM.
   */
  ret = bgp_msg_write_notification(connection, connection->notification) ;

  connection->notification_pending = (ret >= 0) ;
                                  /* is pending if not failed           */
  if      (ret > 0)
    /* notification reached the TCP buffers instantly
     *
     * Send ourselves the good news !
     */
    bgp_fsm_event(connection, bgp_fsm_Sent_NOTIFICATION_message) ;

  else if (ret == 0)
    /* notification is sitting in the write buffer
     *
     * Set notification_pending so that write action will raise the required
     * event in due course.
     *
     * Set the HoldTimer to something suitable.  Don't really expect this
     * to happen in anything except Established state -- but copes.  (Is
     * ready to wait 20 seconds in Stopping state and 5 otherwise.)
     */
    bgp_hold_timer_set(connection, (next_state == bgp_fsm_Stopping) ? 20 : 5) ;

  /* Return suitable state.                                             */
  return next_state ;
} ;

/*==============================================================================
 * The BGP connections timers handling.
 *
 * The FSM has four timers:
 *
 *   * IdleHoldTimer -- uses connection.hold_timer with jitter
 *
 *     This runs while in Idle state, and is a period in which no connections
 *     are started, and none will be accepted.
 *
 *     The purpose of this timer is to slow down re-making connections with
 *     peers who are flapping or otherwise proving a nuisance.
 *
 *     This is a one shot timer, which generates a bgp_fsm_BGP_Start event.
 *
 *   * ConnectRetryTimer -- uses connection.hold_timer with jitter
 *
 *     This runs while in Connect or Active state, and is the period for which
 *     the connection is prepared to wait between attempts to connect.
 *
 *     When trying to make a connect connection:
 *
 *       The FSM will be in Connect state.
 *
 *       If listen connections are enabled, will be listening.
 *
 *       If nothing happens before the ConnectRetryTimer expires, then
 *       the connection attempt will be abandoned, and another started.
 *
 *       If the connection attempt fails, moves to Active state -- with the
 *       timer still running.
 *
 *       If nothing further happens before the ConnectRetryTimer expires,
 *       another connect will be started and the FSM returns to Connect state.
 *
 *     When only listening is enabled:
 *
 *       The FSM will be in Active state (!).
 *
 *       If nothing happens before the ConnectRetryTimer expires, then the
 *       FSM will loop round back into Active state.
 *
 *     This timer is recharged each time it goes off, and generates a
 *     bgp_fsm_ConnectRetry_timer_expired event.
 *
 *  * HoldTimer  -- uses connection.hold_timer *without* jitter
 *
 *    This timer is used in OpenSent state, and limits the time will wait for
 *    an Open to appear from the other end.  RFC4271 calls for this to be a
 *    "large value" -- suggesting 240 seconds.
 *
 *    This timer is also used in OpenConfirm and Established states, and limits
 *    the time the connection will be held if hear nothing from the other end.
 *    In these states the timer is set to the negotiated HoldTime.  If this is
 *    zero, then the HoldTime is infinite.
 *
 *    This is a one shot timer, which generates a bgp_fsm_Hold_Timer_expired
 *    event.
 *
 *  * KeepaliveTimer -- uses connection.keepalive_timer with jitter.
 *
 *    This timer is used in OpenConfirm and Established states only.
 *
 *    The default KeepalineTimer is 1/3 the HoldTimer, and is set from the
 *    negotiated HoldTime.  If that is zero, then the KeepaliveTime is also
 *    infinite, and no KEEPALIVE messages will be sent (other than the "ack"
 *    of the OPEN message).
 *
 *    This timer is recharged each time it goes off, and generates a
 *    bgp_fsm_KeepAlive_timer_expired event.
 */

/* Forward reference                                                    */
static void
bgp_timer_set(bgp_connection connection, qtimer timer, unsigned secs,
                                            int jitter, qtimer_action* action) ;

/* Forward reference the action functions                               */
static qtimer_action bgp_idle_hold_timer_action ;
static qtimer_action bgp_connect_retry_timer_action ;
static qtimer_action bgp_hold_timer_action ;
static qtimer_action bgp_keepalive_timer_action ;

/*==============================================================================
 * Completion of State Change
 *
 * This performs fixed changes associated with the entry to each state from
 * *another* state.
 *
 * connection->state == current (soon to be old) state
 *
 * Set and unset all the connection timers as required by the new state of
 * the connection -- which may depend on the current state.
 *
 * NB: requires the session LOCKED
 */
static void
bgp_fsm_state_change(bgp_connection connection, bgp_fsm_state_t new_state)
{
  bgp_connection sibling ;
  unsigned  interval ;
  bgp_session    session = connection->session ;

  switch (new_state)
    {
    /* Base state of connection's finite state machine -- when a session has
     * been enabled.  Falls back to Idle in the event of various errors.
     *
     * In Idle state:
     *
     *   either: the IdleHoldTimer is running, at the end of which the
     *           BGP Engine will try to connect.
     *
     *       or: the connection is comatose, in which case will stay that way
     *           until sibling connection also falls back to Idle (from
     *           OpenSent/OpenConfirm.
     *
     * When entering Idle from anything other than Initial state, and not
     * falling into a coma, extend the IdleHoldTimer.
     *
     * In Idle state refuses connections.
     */
    case bgp_fsm_Idle:
      interval = session->idle_hold_timer_interval ;
      sibling  = bgp_connection_get_sibling(connection) ;

      if (connection->state == bgp_fsm_Initial)
        interval = (interval > 0) ? interval : 1 ;  /* may not be zero  */
      else
        {
          if ( (sibling != NULL)
                && (   (sibling->state == bgp_fsm_OpenSent)
                    || (sibling->state == bgp_fsm_OpenConfirm) ) )
            {
              interval = 0 ;              /* unset the HoldTimer        */
              connection->comatose = 1 ;  /* so now comatose            */
            }
          else
            {
              /* increase the IdleHoldTimer interval                    */
              interval *= 2 ;

              if      (interval < 4)      /* enforce this minimum       */
                interval = 4 ;
              else if (interval > 120)
                interval = 120 ;

              session->idle_hold_timer_interval = interval ;

              /* if sibling is comatose, set time for it to come round  */

              if ((sibling != NULL) && (sibling->comatose))
                {
                  connection->comatose = 0 ;    /* no longer comatose   */
                  bgp_timer_set(sibling, &sibling->hold_timer, interval, 1,
                                                   bgp_idle_hold_timer_action) ;
                } ;
            } ;
        } ;

      bgp_timer_set(connection, &connection->hold_timer, interval, 1,
                                                   bgp_idle_hold_timer_action) ;

      qtimer_unset(&connection->keepalive_timer) ;

      break;

    /* In Connect state the BGP Engine is attempting to make a connection
     * with the peer and may be listening for a connection.
     *
     * In Active state the BGP Engine is only listening (!).
     *
     * In both cases, waits for the connect_hold_timer_interval.
     *
     * The ConnectRetryTimer automatically recharges, because will loop back
     * round into the same state.
     */
    case bgp_fsm_Connect:
    case bgp_fsm_Active:
      bgp_timer_set(connection, &connection->hold_timer,
                           session->connect_retry_timer_interval, 1,
                                               bgp_connect_retry_timer_action) ;
      qtimer_unset(&connection->keepalive_timer) ;
      break;

    /* In OpenSent state is waiting for an OPEN from the other end, before
     * proceeding to OpenConfirm state.
     *
     * Prepared to wait for quite a long time for this.
     *
     * Note that session->accept is left as it is.  If have reached OpenSent
     * on:
     *
     *   * a connect() connection, then session->accept will be true and will
     *     still accept in-bound connections.
     *
     *   * an accept() connection, then session->accept will be false.
     */
    case bgp_fsm_OpenSent:
      bgp_hold_timer_set(connection, session->open_hold_timer_interval) ;
      qtimer_unset(&connection->keepalive_timer) ;
      break;

    /* In OpenConfirm state is waiting for an "ack" before proceeding to
     * Established.  Session->accept is left as it is.  If have reached
     * OpenConfirm on:
     *
     *   * a connect() connection, then session->accept may still be true and
     *     will still accept in-bound connections.  (Collision detection may
     *     have discarded an accept() connection already.)
     *
     *   * an accept() connection, then session->accept will be false.
     *
     * There is only one way into Established, and that is from OpenConfirm.
     * OpenConfirm starts the KeepaliveTimer.  It would be wrong to reset the
     * timer on entry to Established.
     *
     * In both cases have just received a message, so can restart the HoldTimer.
     *
     * Both use the negotiated Hold Time and Keepalive Time.  May send further
     * KEEPALIVE messages in OpenConfirm.
     *
     * If the negotiated Hold Time value is zero, then the Keepalive Time
     * value will also be zero, and this will unset both timers.
     */
    case bgp_fsm_OpenConfirm:
      bgp_timer_set(connection, &connection->keepalive_timer,
                                 connection->keepalive_timer_interval, 1,
                                                   bgp_keepalive_timer_action) ;
    case bgp_fsm_Established:
      bgp_hold_timer_set(connection, connection->hold_timer_interval) ;
      break;

    /* The connection is coming to an dead stop.
     *
     * If not sending a NOTIFICATION then stop HoldTimer now.
     *
     * Unlink connection from session.
     */
    case bgp_fsm_Stopping:
      if (!connection->notification_pending)
        qtimer_unset(&connection->hold_timer) ;

      qtimer_unset(&connection->keepalive_timer) ;

      session->connections[connection->ordinal] = NULL ;
      connection->session = NULL ;
      connection->p_mutex = NULL ;

      break ;

    default:
      zabort("Unknown bgp_fsm_state") ;
    } ;

  /* Finally: set the new state                                         */
  connection->state = new_state ;
} ;

/*==============================================================================
 * Timer set and Timer Action Functions
 */

/*------------------------------------------------------------------------------
 * Start or reset given qtimer with given interval, in seconds.
 *
 * If the interval is zero, unset the timer.
 */
static void
bgp_timer_set(bgp_connection connection, qtimer timer, unsigned secs,
                                              int jitter, qtimer_action* action)
{
  if (secs == 0)
    qtimer_unset(timer) ;
  else
    {
      secs *= 40 ;      /* a bit of resolution for jitter       */
      if (jitter)
        secs -= ((rand() % ((int)secs + 1)) / 4) ;
      qtimer_set_interval(timer, QTIME(secs) / 40, action) ;
    } ;
} ;

/*------------------------------------------------------------------------------
 * Set HoldTimer with given time (without jitter) so will generate a
 * Hold_Timer_expired event.
 *
 * Setting 0 will unset the HoldTimer.
 */
static void
bgp_hold_timer_set(bgp_connection connection, unsigned secs)
{
  bgp_timer_set(connection, &connection->hold_timer, secs, 0,
                                                        bgp_hold_timer_action) ;
} ;

/*------------------------------------------------------------------------------
 * Recharge the HoldTimer
 */

static void
bgp_hold_timer_recharge(bgp_connection connection)
{
  bgp_hold_timer_set(connection, connection->hold_timer_interval) ;
} ;

/*------------------------------------------------------------------------------
 * BGP start timer action => bgp_fsm_BGP_Start event
 *
 * The timer is automatically unset, which is fine.
 */
static void
bgp_idle_hold_timer_action(qtimer qtr, void* timer_info, qtime_mono_t when)
{
  bgp_connection connection = timer_info ;

  BGP_FSM_DEBUG(connection, "Timer (start timer expire)") ;

  bgp_fsm_event(connection, bgp_fsm_BGP_Start) ;
} ;

/*------------------------------------------------------------------------------
 * BGP connect retry timer => bgp_fsm_ConnectRetry_timer_expired event
 *
 * The timer is recharged here, applying a new "jitter", but that may be
 * overridden by the bgp_event() handling.
 */
static void
bgp_connect_retry_timer_action(qtimer qtr, void* timer_info, qtime_mono_t when)
{
  bgp_connection connection = timer_info ;

  BGP_FSM_DEBUG(connection, "Timer (connect timer expire)") ;

  bgp_timer_set(connection, &connection->hold_timer,
           connection->session->connect_retry_timer_interval, 1, NULL) ;

  bgp_fsm_event(connection, bgp_fsm_ConnectRetry_timer_expired) ;
} ;

/*------------------------------------------------------------------------------
 * BGP hold timer => bgp_fsm_Hold_Timer_expired event
 *
 * The timer is automatically unset, which is fine.
 */
static void
bgp_hold_timer_action(qtimer qtr, void* timer_info, qtime_mono_t when)
{
  bgp_connection connection = timer_info ;

  BGP_FSM_DEBUG(connection, "Timer (holdtime timer expire)") ;

  bgp_fsm_event(connection, bgp_fsm_Hold_Timer_expired) ;
} ;

/*------------------------------------------------------------------------------
 * BGP keepalive fire => bgp_fsm_KeepAlive_timer_expired
 *
 * The timer is recharged here, applying a new "jitter", but that may be
 * overridden by the bgp_event() handling.
 */
static void
bgp_keepalive_timer_action(qtimer qtr, void* timer_info, qtime_mono_t when)
{
  bgp_connection connection = timer_info ;

  BGP_FSM_DEBUG(connection, "Timer (keepalive timer expire)") ;

  bgp_timer_set(connection, &connection->keepalive_timer,
                    connection->session->keepalive_timer_interval, 1, NULL) ;

  bgp_fsm_event(connection, bgp_fsm_KeepAlive_timer_expired) ;
} ;

/*============================================================================*/
/* BGP Peer Down Cause */
/* TODO: this is also defined in bgp_peer.c */
#if 0
const char *peer_down_str[] =
{
  "",
  "Router ID changed",
  "Remote AS changed",
  "Local AS change",
  "Cluster ID changed",
  "Confederation identifier changed",
  "Confederation peer changed",
  "RR client config change",
  "RS client config change",
  "Update source change",
  "Address family activated",
  "Admin. shutdown",
  "User reset",
  "BGP Notification received",
  "BGP Notification send",
  "Peer closed the session",
  "Neighbor deleted",
  "Peer-group add member",
  "Peer-group delete member",
  "Capability changed",
  "Passive config change",
  "Multihop config change",
  "NSF peer closed the session"
};
#endif