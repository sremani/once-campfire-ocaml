use campfire_richtext::{
    AttachableResolver, GidLookup, MentionUser, Presentation, RenderContext, SignedLookup,
    editable_value, present_message, to_plain_text,
};
use serde_json::Value;
struct Resolver {
    users: Vec<MentionUser>,
    rooms: Vec<i64>,
    signed: Vec<(String, String, i64, bool)>,
}
impl AttachableResolver for Resolver {
    fn locate_signed(&self, sgid: &str) -> SignedLookup {
        match self.signed.iter().find(|(s, ..)| s == sgid) {
            Some((_, model, id, true)) if model == "User" => {
                SignedLookup::User(self.users.iter().find(|u| u.id == *id).unwrap().clone())
            }
            Some((_, model, _, _)) => SignedLookup::MissingRecord {
                model_name: model.clone(),
            },
            None => SignedLookup::Invalid,
        }
    }
    fn find_gid(&self, gid: &str) -> GidLookup {
        let Some(rest) = gid.strip_prefix("gid://") else {
            return GidLookup::NotFound;
        };
        if !gid.is_ascii() {
            return GidLookup::NotFound;
        }
        let Some((_app, rest)) = rest.split_once('/') else {
            return GidLookup::NotFound;
        };
        let rest = rest.split('?').next().unwrap();
        let Some((model, id)) = rest.split_once('/') else {
            return GidLookup::NotFound;
        };
        let Ok(id) = id.parse::<i64>() else {
            return GidLookup::NotFound;
        };
        match model {
            "User" => self
                .users
                .iter()
                .find(|u| u.id == id)
                .cloned()
                .map_or(GidLookup::NotFound, GidLookup::User),
            "Room" if self.rooms.contains(&id) => GidLookup::OtherModel,
            _ => GidLookup::NotFound,
        }
    }
}
fn main() {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../once-campfire-rust/crates/richtext/tests/corpus/expected.json");
    let corpus: Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    let users = corpus["users"]
        .as_array()
        .unwrap()
        .iter()
        .map(|u| MentionUser {
            id: u["id"].as_i64().unwrap(),
            name: u["name"].as_str().unwrap().into(),
            title: u["title"].as_str().unwrap().into(),
            attachable_sgid: u["attachable_sgid"].as_str().unwrap().into(),
            user_path: u["user_path"].as_str().unwrap().into(),
            avatar_path: u["avatar_path"].as_str().unwrap().into(),
        })
        .collect();
    let rooms = corpus["rooms"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r.as_i64().unwrap())
        .collect();
    let signed = corpus["signed"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| {
            (
                s["sgid"].as_str().unwrap().into(),
                s["model"].as_str().unwrap().into(),
                s["id"].as_i64().unwrap(),
                s["exists"].as_bool().unwrap(),
            )
        })
        .collect();
    let resolver = Resolver {
        users,
        rooms,
        signed,
    };
    for case in corpus["cases"].as_array().unwrap() {
        let name = case["name"].as_str().unwrap();
        let body = case["body"].as_str().unwrap();
        let ctx = RenderContext {
            resolver: &resolver,
            request_host: case["host"].as_str().map(str::to_string),
        };
        let presentation = match present_message(body, &ctx) {
            Presentation::Html(html) => serde_json::json!({"ok":html}),
            Presentation::Unrenderable => serde_json::json!({"error":"unrenderable"}),
        };
        let editable = match editable_value(body, &ctx) {
            Ok(v) => serde_json::json!({"ok":v}),
            Err(e) => serde_json::json!({"error":format!("{e:?}")}),
        };
        let plain_text = match to_plain_text(body, &ctx) {
            Ok(value) => serde_json::json!({"ok":value}),
            Err(error) => serde_json::json!({"error":format!("{error:?}")}),
        };
        println!(
            "{}",
            serde_json::json!({"name":name,"presentation":presentation,"plain_text":plain_text,"editable":editable})
        );
    }
}
