use axum::{
    body::{to_bytes, Body},
    http::{Request, StatusCode},
    response::Response,
    Router,
};
use serde_json::{json, Value};
use std::{os::unix::fs::PermissionsExt, path::PathBuf, sync::Arc};
use tower::ServiceExt;

struct Fixture {
    dir: PathBuf,
    app: Option<Router>,
}

impl Fixture {
    async fn new() -> Self {
        let dir = std::env::temp_dir().join(format!("lalune-panel-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&dir).unwrap();
        let state = Arc::new(crate::state::AppState::new_in(dir.clone()).await.unwrap());
        Self { dir, app: Some(crate::api::router(state)) }
    }

    async fn send(&self, method: &str, uri: &str, payload: Value) -> Response {
        self.app.as_ref().unwrap().clone().oneshot(Request::builder()
            .method(method).uri(uri).header("content-type", "application/json")
            .body(Body::from(payload.to_string())).unwrap()).await.unwrap()
    }

    async fn json(&self, method: &str, uri: &str, payload: Value, status: StatusCode) -> Value {
        let response = self.send(method, uri, payload).await;
        assert_eq!(response.status(), status);
        let bytes = to_bytes(response.into_body(), 256 * 1024).await.unwrap();
        serde_json::from_slice(&bytes).unwrap()
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        drop(self.app.take());
        assert_eq!(self.dir.canonicalize().unwrap().parent().unwrap(),
            std::env::temp_dir().canonicalize().unwrap());
        std::fs::remove_dir_all(&self.dir).unwrap();
    }
}

#[tokio::test]
async fn settings_api_persists_auto_mode_without_changing_manual_workers() {
    let fixture = Fixture::new().await;
    let settings = fixture.json("GET", "/settings", Value::Null, StatusCode::OK).await;
    assert_eq!(settings["autoWorkers"], false);

    fixture.json("PATCH", "/settings", json!({"workers": 37, "autoWorkers": true}), StatusCode::OK).await;
    let settings = fixture.json("GET", "/settings", Value::Null, StatusCode::OK).await;
    assert_eq!(settings["autoWorkers"], true);
    assert_eq!(settings["workers"], 37);

    fixture.json("PUT", "/settings/autoWorkers", json!(false), StatusCode::OK).await;
    let stored: Value = serde_json::from_slice(&std::fs::read(fixture.dir.join("settings.json")).unwrap()).unwrap();
    assert_eq!(stored["autoWorkers"], false);
    assert_eq!(stored["workers"], 37);
}

#[tokio::test]
async fn panel_assets_are_served_with_same_origin_policy() {
    let fixture = Fixture::new().await;
    for (path, kind) in [
        ("/panel", "text/html"),
        ("/panel/", "text/html"),
        ("/panel/panel.css", "text/css"),
        ("/panel/panel.js", "text/javascript"),
    ] {
        let response = fixture.send("GET", path, Value::Null).await;
        assert_eq!(response.status(), StatusCode::OK);
        assert!(response.headers()["content-type"].to_str().unwrap().starts_with(kind));
        assert_eq!(response.headers()["cache-control"], "no-store");
        assert!(response.headers()["content-security-policy"].to_str().unwrap().contains("connect-src 'self'"));
    }
}

#[tokio::test]
async fn panel_can_import_profile_and_validate_auto_api_without_network() {
    let fixture = Fixture::new().await;
    let imported = fixture.json("POST", "/configs", json!({
        "protocol": "CSQTT 2.5.1",
        "name": "Example",
        "link": "csqtt://connect?v=2&host=192.0.2.2&peer=46000&password=fixture-password&hashes=a+b",
    }), StatusCode::OK).await;
    let id = imported["id"].as_i64().unwrap();
    fixture.json("PUT", "/configs/selected", json!({"id": id}), StatusCode::OK).await;
    let config = fixture.json("GET", "/configs/selected", Value::Null, StatusCode::OK).await;
    assert_eq!(config["protocol"], "CSQTT");
    assert_eq!(config["name"], "Example");
    assert_eq!(config["peer"], "192.0.2.2:46000");
    fixture.json("PATCH", "/settings", json!({"authMode":"autoApi"}), StatusCode::OK).await;
    fixture.json("POST", "/vpn/connect", json!({"configId":id}), StatusCode::BAD_REQUEST).await;
    fixture.json("POST", "/vk/token/submit", json!({"token":" "}), StatusCode::BAD_REQUEST).await;
    fixture.json("POST", "/vk/token/submit", json!({"token":"fixture-vk-token"}), StatusCode::OK).await;
    let token = fixture.json("GET", "/vk/token/state", Value::Null, StatusCode::OK).await;
    assert_eq!(token["hasToken"], true);
    assert!(!token.to_string().contains("fixture-vk-token"));
    let path = fixture.dir.join("token.json");
    assert_eq!(std::fs::metadata(path).unwrap().permissions().mode() & 0o777, 0o600);
}

#[tokio::test]
async fn idle_backend_rejects_active_only_probe() {
    let fixture = Fixture::new().await;
    fixture.json("POST", "/vpn/measure", json!({"temporary":false,"configId":1}), StatusCode::CONFLICT).await;
    let status = fixture.json("GET", "/vpn/status", Value::Null, StatusCode::OK).await;
    assert_eq!(status["state"], "disconnected");
}

#[tokio::test]
async fn failed_temporary_probe_preserves_selection_and_does_not_create_profile() {
    let fixture = Fixture::new().await;
    let link = "csqtt://connect?v=2&host=192.0.2.2&peer=46000&password=fixture-password&hashes=a+b";
    let profile = fixture.json("POST", "/configs", json!({"protocol":"CSQTT","link":link}), StatusCode::OK).await;
    let id = profile["id"].as_i64().unwrap();
    fixture.json("PUT", "/configs/selected", json!({"id":id}), StatusCode::OK).await;
    fixture.json("PATCH", "/settings", json!({"authMode":"autoApi"}), StatusCode::OK).await;
    fixture.json("POST", "/vpn/measure", json!({"temporary":true,"link":link,"protocol":"CSQTT"}), StatusCode::BAD_REQUEST).await;
    let status = fixture.json("GET", "/vpn/status", Value::Null, StatusCode::OK).await;
    assert_eq!(status["state"], "disconnected");
    let selected = fixture.json("GET", "/configs/selected", Value::Null, StatusCode::OK).await;
    assert_eq!(selected["id"], id);
    let profiles = fixture.json("GET", "/configs", Value::Null, StatusCode::OK).await;
    assert_eq!(profiles.as_array().unwrap().len(), 1);
}
