use std::sync::Arc;
use std::time::Duration;
use std::time::Instant;

use codex_code_mode_protocol::CellId;
use codex_code_mode_protocol::RuntimeResponse;
use codex_code_mode_protocol::StartedCell;
use codex_code_mode_protocol::host::DelegateRequest;
use codex_code_mode_protocol::host::EncodedFrame;
use codex_code_mode_protocol::host::HostToClient;
use codex_code_mode_protocol::host::RequestId;
use codex_code_mode_protocol::host::SessionId;
use codex_code_mode_protocol::host::WireResult;
use pretty_assertions::assert_eq;
use tokio::sync::Semaphore;
use tokio::sync::mpsc;
use tokio::sync::oneshot;
use tokio::sync::oneshot::error::TryRecvError;
use tokio_util::sync::CancellationToken;

use super::HostPeer;
use super::MAX_PENDING_DELEGATE_CALLS;

fn session_id(value: &str) -> SessionId {
    SessionId::new(value).expect("session ID")
}

fn response_message(value: i64) -> HostToClient {
    HostToClient::Response {
        id: RequestId::new(value),
        result: WireResult::Err {
            message: format!("response-{value}"),
        },
    }
}

fn encoded_bytes(message: &HostToClient) -> Vec<u8> {
    EncodedFrame::encode(message)
        .expect("encode test frame")
        .into_framed_bytes()
}

#[tokio::test]
async fn start_cell_reports_when_initial_response_is_enqueued() {
    let (outgoing_tx, mut outgoing_rx) = mpsc::channel(/*max_capacity*/ 4);
    let peer = Arc::new(HostPeer::new(outgoing_tx));
    let cell_id = CellId::new("cell-1".to_string());
    let (response_tx, response_rx) = oneshot::channel();
    let started = StartedCell::new(cell_id.clone(), response_rx);
    let active_cell_permits = Arc::new(Semaphore::new(/*permits*/ 1));
    let active_cell_permit = Arc::clone(&active_cell_permits)
        .try_acquire_owned()
        .expect("active cell permit");

    let mut initial_response_sent = peer.start_cell(
        session_id("session-1"),
        RequestId::new(/*value*/ 1),
        started,
        active_cell_permit,
        Instant::now(),
    );
    assert_eq!(initial_response_sent.try_recv(), Err(TryRecvError::Empty));

    response_tx
        .send(RuntimeResponse::Result {
            code_mode_host_duration: None,
            cell_id: cell_id.clone(),
            content_items: Vec::new(),
            error_text: None,
        })
        .expect("initial response receiver");
    initial_response_sent
        .await
        .expect("initial response completion");
    outgoing_rx.recv().await.expect("initial response frame");
    assert_eq!(active_cell_permits.available_permits(), 0);

    peer.close_cell(session_id("session-1"), cell_id);
    let permit = tokio::time::timeout(
        Duration::from_secs(1),
        Arc::clone(&active_cell_permits).acquire_owned(),
    )
    .await
    .expect("cell permit should be released")
    .expect("cell permit semaphore should remain open");
    drop(permit);
}

#[tokio::test]
async fn pending_delegate_limit_rejects_call_without_disconnecting() {
    let (outgoing_tx, _outgoing_rx) = mpsc::channel(/*max_capacity*/ 1);
    let peer = Arc::new(HostPeer::new(outgoing_tx));
    let permits = Arc::clone(&peer.delegate_permits)
        .acquire_many_owned(MAX_PENDING_DELEGATE_CALLS as u32)
        .await
        .expect("delegate permits");

    let result = peer
        .call(
            session_id("session-1"),
            DelegateRequest::Notify {
                call_id: "call-1".to_string(),
                cell_id: CellId::new("cell-1".to_string()).into(),
                text: "hello".to_string(),
            },
            CancellationToken::new(),
        )
        .await;

    assert_eq!(
        result,
        Err("code-mode host has too many pending delegate calls".to_string())
    );
    assert!(!peer.is_disconnected());
    drop(permits);
}

#[tokio::test]
async fn full_outgoing_queue_backpressures_without_disconnecting() {
    let (outgoing_tx, mut outgoing_rx) = mpsc::channel(/*max_capacity*/ 1);
    let peer = Arc::new(HostPeer::new(outgoing_tx));
    peer.send(response_message(/*value*/ 1))
        .await
        .expect("enqueue first response");

    let blocked_peer = Arc::clone(&peer);
    let blocked_send = tokio::spawn(async move {
        blocked_peer.send(response_message(/*value*/ 2)).await
    });
    tokio::task::yield_now().await;

    assert!(!blocked_send.is_finished());
    assert!(!peer.is_disconnected());
    assert_eq!(
        outgoing_rx
            .recv()
            .await
            .expect("first response")
            .into_framed_bytes(),
        encoded_bytes(&response_message(/*value*/ 1))
    );
    blocked_send
        .await
        .expect("blocked send task")
        .expect("enqueue second response");
    assert_eq!(
        outgoing_rx
            .recv()
            .await
            .expect("second response")
            .into_framed_bytes(),
        encoded_bytes(&response_message(/*value*/ 2))
    );
    assert!(!peer.is_disconnected());
}

#[tokio::test]
async fn bounded_queue_preserves_fifo_order_for_512_cell_class_burst() {
    const CELL_CLASS_BURST: i64 = 512;
    let (outgoing_tx, mut outgoing_rx) = mpsc::channel(/*max_capacity*/ 8);
    let peer = Arc::new(HostPeer::new(outgoing_tx));
    let producer = tokio::spawn(async move {
        for value in 0..CELL_CLASS_BURST {
            peer.send(response_message(value)).await?;
        }
        Ok::<(), super::PeerSendError>(())
    });

    for value in 0..CELL_CLASS_BURST {
        assert_eq!(
            outgoing_rx
                .recv()
                .await
                .expect("burst response")
                .into_framed_bytes(),
            encoded_bytes(&response_message(value))
        );
    }
    producer
        .await
        .expect("burst producer task")
        .expect("enqueue burst");
}
