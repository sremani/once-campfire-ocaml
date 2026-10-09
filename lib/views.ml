(* Tyxml is the sole encoder for text and attribute values. Fragments can only be
   assembled through the constructors below, except at the explicit trusted rich
   text boundary. Message fragments contain relative links for cache safety. *)
module H = Tyxml.Html

type fragment = Fragment of string
type trusted_html = Trusted_html of string
let render (Fragment html) = html
let from_elt elt = Fragment (Format.asprintf "%a" (H.pp_elt ()) elt)
let text value = from_elt (H.txt value)
let concat parts = Fragment (String.concat "" (List.map render parts))
let raw (Trusted_html value) = Fragment value
let trusted_html_of_sanitized value = Trusted_html value
let attr (name, value) = H.Unsafe.string_attrib name value
let elt name attributes children =
  let nodes = List.map (fun child -> H.Unsafe.data (render child)) children in
  from_elt (H.Unsafe.node name ~a:(List.map attr attributes) nodes)
let void name attributes = from_elt (H.Unsafe.leaf name ~a:(List.map attr attributes) ())
let a href children = elt "a" ["href",href] children
let cls name class_name children = elt name ["class",class_name] children
let id name identifier children = elt name ["id",identifier] children
let image ?(width=24) ?(height=24) ?(alt="") src =
  void "img" ["src",src;"alt",alt;"width",string_of_int width;"height",string_of_int height]
let i64 = Int64.to_string
let relative_user user_id = "/users/" ^ i64 user_id
let relative_room room_id = "/rooms/" ^ i64 room_id
let relative_message room_id message_id =
  relative_room room_id ^ "/messages/" ^ i64 message_id
let relative_at_message room_id message_id =
  relative_room room_id ^ "/@" ^ i64 message_id

type user = { id:int64; name:string; title:string; avatar_url:string; role:string }
type context = {
  base_url:string; account_name:string; logo_url:string; has_custom_logo:bool;
  current_user:user option;
  platform:User_agent.view;
  assets:(string * string) list; stylesheet_tags:trusted_html option;
  importmap_tags:trusted_html option; custom_styles:string option;
  vapid_public_key:string option; app_version:string;
  flash_notice:string option; flash_alert:string option;
}
let default_context = {
  base_url=""; account_name="Campfire"; logo_url="/assets/campfire-icon.png";
  has_custom_logo=false;
  current_user=None; platform=User_agent.to_view (User_agent.application_platform None);
  assets=[]; stylesheet_tags=None; importmap_tags=None;
  custom_styles=None; vapid_public_key=None; app_version="0";
  flash_notice=None; flash_alert=None;
}
let asset ctx name = match List.assoc_opt name ctx.assets with
  | Some path -> path
  | None -> (try Assets.asset_path name with _ -> "/assets/" ^ name)
let lexxy_ready_head = elt "script" [] [raw (Trusted_html {|
  document.addEventListener("lexxy:initialize", (event) => {
    const editor = event.target;
    if (!editor.matches?.("lexxy-editor[data-wait-for-mount]")) return;
    const revealWhenMounted = () => {
      if (!editor.isConnected || !editor.hasAttribute("data-wait-for-mount")) return;
      if (editor.editor?.getRootElement()) {
        editor.style.visibility = "";
        editor.removeAttribute("data-wait-for-mount");
      } else {
        requestAnimationFrame(revealWhenMounted);
      }
    };
    revealWhenMounted();
  });
|})]

(* Rails/Askama preserve the layout's literal whitespace and serialize some
   tags differently from Tyxml. Dynamic text and attributes still pass
   through Tyxml's encoder. *)
let legacy_text value = render (text value)
let legacy_attribute value =
  let encoded=render (void "x" ["data-value",value]) in
  let prefix="<x data-value=\"" in
  let closing_quote=String.index_from encoded (String.length prefix) '"' in
  String.sub encoded (String.length prefix)
    (closing_quote - String.length prefix)
let legacy_img ?(size=None) context name attributes =
  let attributes=attributes @ ["src",asset context name] @
    (match size with None -> [] | Some size ->
      ["width",string_of_int size;"height",string_of_int size]) in
  "<img " ^ String.concat " " (List.map (fun (key,value) ->
    key ^ "=\"" ^ legacy_attribute value ^ "\"") attributes) ^ " />"
let legacy_lightbox context =
  String.concat "" [
    {|<dialog class="lightbox" aria-label="Image Viewer (Press escape to close)" data-lightbox-target="dialog" data-action="close->lightbox#reset">
  <img src="" class="lightbox__image" data-lightbox-target="zoomedImage" />

  <form method="dialog" class="lightbox__btn">
    <button class="btn">
      |};
    legacy_img context "remove.svg" ["aria-hidden","true"];
    {|
      <span class="for-screen-reader">Close image viewer</span>
    </button>
  </form>

  <a href="" class="lightbox__btn--download btn hide-in-ios-pwa" data-lightbox-target="download">
    |};
    legacy_img context "download.svg" ["aria-hidden","true"];
    {|
    <span class="for-screen-reader">Download file</span>
  </a>

  <button class="lightbox__btn--share btn"
      data-controller="web-share"
      data-action="web-share#share"
      data-web-share-files-value=""
      data-lightbox-target="share">
    |};
    legacy_img context "share.svg" ["aria-hidden","true"];
    {|
    <span class="for-screen-reader">Share file</span>
  </button>
</dialog>
|}]
let legacy_flash context =
  match context.flash_notice,context.flash_alert with
  | None,None -> ""
  | notice,alert ->
      let shown=Option.value (match notice with Some _ -> notice | None -> alert) ~default:"" in
      let negative=Option.is_some alert in
      String.concat "" [
        {|      <div class="flash" data-controller="element-removal" data-action="animationend->element-removal#remove">
        <div class="flash__inner shadow" style="|};
        (if negative then "--flash-background: var(--color-negative)" else "");
        {|">
            |};
        legacy_img ~size:(Some 24) context
          (if negative then "alert.svg" else "check.svg")
          ["aria-hidden","true";"class","colorize--white"];
        "</span>\n";
        {|        </div>
        <span class="for-screen-reader" role="alert" aria-atomic="true">|};
        legacy_text shown;
        {|</span>
      </div>
|}]
let legacy_page ~context ~title ~body_class ~head ~nav ~content ~footer
    ~sidebar =
  let stylesheet=Option.fold ~none:"" ~some:(fun (Trusted_html s)->s)
    context.stylesheet_tags in
  let importmap=Option.fold ~none:"" ~some:(fun (Trusted_html s)->s)
    context.importmap_tags in
  let custom_styles=match context.custom_styles with None -> ""
    | Some css -> "<style data-turbo-track=\"reload\">" ^ css ^ "</style>" in
  let current_user_meta=match context.current_user with None -> ""
    | Some user -> String.concat "" [
        "<meta name=\"current-user-id\" content=\"" ^ i64 user.id ^ "\" />";
        "<meta name=\"current-user-name\" content=\"" ^
          legacy_attribute user.name ^ "\" />"] in
  let body_class=String.concat " " (List.filter ((<>) "") [
    body_class;
    (match context.current_user with Some user when user.role="administrator" -> "admin" | _ -> "");
    (if context.has_custom_logo then "account-has-logo" else "")]) in
  String.concat "" [
    {|<!DOCTYPE html>
<html>
  <head>
    <title>|};legacy_text title;{|</title>

    <meta name="viewport" content="width=device-width, initial-scale=1, user-scalable=no, interactive-widget=resizes-content">
    <meta name="view-transition" content="same-origin">
    <meta name="color-scheme" content="light dark">
    <meta name="theme-color" content="#ffffff" media="(prefers-color-scheme: light)">
    <meta name="theme-color" content="#000000" media="(prefers-color-scheme: dark)">
    <meta name="apple-mobile-web-app-capable" content="yes">
    |};current_user_meta;
    {|
    <meta name="action-cable-url" content="/cable">

    |};
    (match context.vapid_public_key with None -> "" | Some key ->
      "<meta name=\"vapid-public-key\" content=\"" ^ legacy_attribute key ^ "\">");
    {|
    <meta name="turbo-prefetch" content="true">

    <link rel="manifest" href="/webmanifest.json">
    <link rel="icon" href="|};legacy_attribute context.logo_url;
    {|" type="image/png">
    <link rel="apple-touch-icon" href="|};legacy_attribute context.logo_url;
    {|">

    |};stylesheet;
    {|
    |};custom_styles;
    {|

    |};importmap;
    {|

|};head;{|  </head>

  <body class="|};legacy_attribute body_class;
    {|" data-controller="local-time lightbox">
    <a href="#main-content" class="skip-navigation btn">Skip to main content</a>

    <nav id="nav">
|};nav;{|    </nav>

|};legacy_flash context;
    {|
    <main id="main-content">
|};content;
    {|
      <footer id="footer">
|};footer;{|      </footer>
    </main>

    <aside id="sidebar" data-controller="toggle-class" data-toggle-class-toggle-class="open">
|};sidebar;{|    </aside>

    |};legacy_lightbox context;
    {|

    <a href="https://once.com" id="app-logo" target="_blank" aria-label="Once software from 37signals home page">
      |};
    legacy_img context "campfire-icon.png"
      ["alt","Campfire logo";"width","256";"height","216"];
    {|
    </a>
  </body>
</html>
|}]

let page ?title ?(body_class="") ?(head=concat []) ?(nav=concat [])
    ?(sidebar=concat []) ?(footer=concat []) ~context content =
  legacy_page ~context ~title:(Option.value title ~default:"Campfire")
    ~body_class ~head:(render head) ~nav:(render nav)
    ~content:(render content) ~footer:(render footer)
    ~sidebar:(render sidebar)

let legacy_session_page ~context ~content =
  legacy_page ~context ~title:"Sign in" ~body_class:""
    ~head:{|<meta name="turbo-visit-control" content="reload">|}
    ~nav:"" ~content ~footer:"" ~sidebar:""

let input ?value ?(required=false) ?(attrs=[]) ~name ~kind () =
  void "input" (["name",name;"type",kind] @
    (match value with None -> [] | Some v -> ["value",v]) @
    (if required then ["required","required"] else []) @ attrs)
let button ?(attrs=[]) label = elt "button" (["type","submit"]@attrs) [text label]
let form ?(method_="post") ?(attrs=[]) action content =
  elt "form" (["action",action;"method",method_]@attrs) [content]
let invite_fragment context join_code =
  let url=context.base_url ^ Route_helpers.join join_code in
  let icon name = void "img" ["aria-hidden","true";
    "class","colorize--black";"src",asset context (name ^ ".svg");
    "width","20";"height","20"] in
  let qr_path=Route_helpers.qr_code (Rails_format.urlsafe_encode ~pad:true url) in
  cls "div" "flex flex-column align-center gap" [
    elt "label" ["class","flex flex-column gap full-width";
      "style","--row-gap: 0.5em"] [
      elt "strong" ["id","invite_label";"class","invite-label"] [
        text "Share to invite more people"];
      cls "span" "flex align-center gap input input--actor fill-white" [
        icon "person-add";
        void "input" ["type","text";"class","input";"id","invite_url";
          "value",url;"aria-labelledby","invite_label";
          "readonly",""]]];
    cls "div" "flex align-center gap" [
      elt "a" ["class","btn";"data-lightbox-target","image";
        "data-action","lightbox#open";
        "data-lightbox-url-value",qr_path;"href",qr_path] [
        cls "span" "for-screen-reader" [text "Show join link QR code"];
        icon "qr-code"];
      elt "button" ["class","btn";
        "data-controller","copy-to-clipboard";
        "data-action","copy-to-clipboard#copy";
        "data-copy-to-clipboard-success-class","btn--success";
        "data-copy-to-clipboard-content-value",url] [
        cls "span" "for-screen-reader" [text "Copy join link"];
        icon "copy-paste"];
      elt "button" ["class","btn";"hidden","hidden";
        "data-controller","web-share";
        "data-action","web-share#share";
        "data-web-share-url-value",url;
        "data-web-share-text-value","Hit this link to join me in Campfire and start chatting.";
        "data-web-share-title-value","Link to join Campfire"] [
        cls "span" "for-screen-reader" [text "Share join link"];
        icon "share"];
      (match context.current_user with
       | Some user when user.role="administrator" ->
           elt "form" ["class","button_to";"method","post";
             "action",Route_helpers.account_join_code ()] [
             elt "button" ["class","btn btn--regenerate";
               "type","submit"] [
               icon "refresh";
               cls "span" "for-screen-reader" [text "Regenerate join link"]]]
       | _ -> concat [])]]
let translations key =
  let flags = ["🇺🇸";"🇪🇸";"🇫🇷";"🇮🇳";"🇩🇪";"🇧🇷";"🇯🇵"] in
  let values = match key with
    | "account_name" -> ["Name this account";"Nombre de esta cuenta";
        "Nommez ce compte";"इस खाते का नाम दें";
        "Benennen Sie dieses Konto";"Dê um nome a essa conta";
        "アカウントに名前を付ける"]
    | "invite_message" -> [
        "Welcome to Campfire. To invite some people to chat with you, share the join link below.";
        "Bienvenido a Campfire. Para invitar a algunas personas a chatear contigo, comparte el enlace de unión que se encuentra a continuación.";
        "Bienvenue sur Campfire. Pour inviter des personnes à discuter avec vous, partagez le lien pour rejoindre ci-dessous.";
        "Campfire में आपका स्वागत है। अधिक लोगों को चैट के लिए आमंत्रित करने के लिए, नीचे जुड़ने का लिंक साझा करें।";
        "Willkommen bei Campfire. Um einige Personen zum Chatten einzuladen, teilen Sie den unten stehenden Beitrittslink.";
        "Boas vindas ao Campfire. Para convidar pessoas para conversarem com você, compartilhe o link de convite abaixo.";
        "Campfireへようこそ。他の人をチャットに招待するには、下記の参加リンクを共有してください。"]
    | "custom_styles" -> [
        "Add custom CSS styles. Use Caution: you could break things.";
        "Agrega estilos CSS personalizados. Usa precaución: podrías romper cosas.";
        "Ajoutez des styles CSS personnalisés. Utilisez avec précaution : vous pourriez casser des choses.";
        "कस्टम CSS स्टाइल जोड़ें। सावधानी बरतें: आप चीज़ों को तोड़ सकते हैं।";
        "Fügen Sie benutzerdefinierte CSS-Stile hinzu. Vorsicht: Sie könnten Dinge kaputt machen.";
        "Adicione estilos CSS personalizados. Use com cuidado: você pode quebrar coisas.";
        "カスタムCSSスタイルを追加。注意: サイトが壊れる可能性があります。"]
    | "user_name" -> ["Enter your name";"Introduce tu nombre";
        "Entrez votre nom";"अपना नाम दर्ज करें";
        "Geben Sie Ihren Namen ein";"Insira seu nome";
        "お名前を入力してください"]
    | "update_password" -> ["Change password";"Cambiar contraseña";
        "Changer le mot de passe";"पासवर्ड बदलें";
        "Passwort ändern";"Alterar senha";
        "パスワードを変更"]
    | "bio" -> ["Enter a few words about yourself.";
        "Ingresa algunas palabras sobre ti mismo.";
        "Saisissez quelques mots à propos de vous-même.";
        "अपने बारे में कुछ शब्द लिखें.";
        "Geben Sie ein paar Worte über sich selbst ein.";
        "Insira alguma palavras sobre você.";
        "ご自分について簡単に記入してください。"]
    | "room_name" -> ["Name the room";"Nombrar la sala";
        "Nommez la salle";"कमरे का नाम दें";
        "Geben Sie dem Raum einen Namen";"Dê um nome a essa sala";
        "ルームに名前を付ける"]
    | "bot_name" -> ["Name the bot";"Nombrar al bot";
        "Nommer le bot";"बॉट का नाम दें";
        "Benenne den Bot";"Dê um nome ao bot";
        "ボットに名前を付ける"]
    | "webhook_url" -> ["Webhook URL";"URL del Webhook";
        "URL du webhook";"वेबहुक URL";
        "Webhook-URL";"URL do Webhook";"Webhook URL"]
    | "chat_bots" -> [
        "Chat bots. With Chat bots, other sites and services can post updates directly to Campfire.";
        "Bots de chat. Con los bots de chat, otros sitios y servicios pueden publicar actualizaciones directamente en Campfire.";
        "Bots de discussion. Avec les bots de discussion, d'autres sites et services peuvent publier des mises à jour directement sur Campfire.";
        "चैट बॉट। चैट बॉट के साथ, अन्य साइटों और सेवाएं सीधे कैम्पफायर में अपडेट पोस्ट कर सकती हैं।";
        "Chat-Bots. Mit Chat-Bots können andere Websites und Dienste Updates direkt in Campfire veröffentlichen.";
        "Chat bots. Com Chat bots, outros sites e serviços podem postar atualizações diretamente no Campfire.";
        "チャットボット。チャットボットを使用すると、他のサイトやサービスがCampfireに直接更新情報を投稿できます。"]
    | "email_address" -> ["Enter your email address";"Introduce tu correo electrónico";
        "Entrez votre adresse courriel";"अपना ईमेल पता दर्ज करें";
        "Geben Sie Ihre E-Mail-Adresse ein";"Insira seu endereço de email";
        "メールアドレスを入力してください"]
    | _ -> ["Enter your password";"Introduce tu contraseña";
        "Saisissez votre mot de passe";"अपना पासवर्ड दर्ज करें";
        "Geben Sie Ihr Passwort ein";"Insira sua senha";
        "パスワードを入力してください"] in
  List.map2 (fun flag value -> concat [elt "dt" [] [text flag];
    elt "dd" ["class","margin-none"] [text value]]) flags values

let translation_button ctx key =
  elt "details" ["class","position-relative";"data-controller","popup";
    "data-action","keydown.esc->popup#close toggle->popup#toggle click@document->popup#closeOnClickOutside";
    "data-popup-orientation-top-class","popup-orientation-top"] [
    elt "summary" ["class","btn";"tabindex","-1"] [
      void "img" ["src",asset ctx "globe.svg";"width","20";"height","20";
        "aria-hidden","true";"class","color-icon"];
      cls "span" "for-screen-reader" [text "Translate"]];
    elt "div" ["class","language-list-menu shadow";"data-popup-target","menu"] [
      cls "dl" "language-list" (translations key)]]

let legacy_translation_button context key =
  String.concat "" [
    {|<details class="position-relative" data-controller="popup" data-action="|};
    legacy_attribute
      "keydown.esc->popup#close toggle->popup#toggle click@document->popup#closeOnClickOutside";
    {|" data-popup-orientation-top-class="popup-orientation-top"><summary class="btn" tabindex="-1">|};
    legacy_img ~size:(Some 20) context "globe.svg"
      ["aria-hidden","true";"class","color-icon"];
    {|<span class="for-screen-reader">Translate</span></summary><div class="language-list-menu shadow" data-popup-target="menu"><dl class="language-list">|};
    String.concat "" (List.map render (translations key));
    {|</dl></div></details>|}]

let legacy_session_content ~context ?email_address ?contact () =
  let field key kind placeholder attributes icon =
    String.concat "" [
      {|        <div class="flex align-center gap">
          |};legacy_translation_button context key;
      {|
          <label class="flex align-center gap input input--actor txt-large">
            <input required="required" class="input" |};
      attributes;
      " placeholder=\"" ^ legacy_attribute placeholder ^ "\"";
      (if key="password" then " maxlength=\"72\" size=\"72\"" else "");
      (match email_address with
       | Some value when key="email_address" ->
           " value=\"" ^ legacy_attribute value ^ "\""
       | _ -> "");
      " type=\"" ^ kind ^ "\" name=\"" ^ key ^ "\" id=\"" ^ key ^ "\" />";
      {|
            |};
      legacy_img ~size:(Some 24) context (icon ^ ".svg")
        ["aria-hidden","true";"class","colorize--black"];
      {|
          </label>
        </div>|}] in
  let help = match contact with
    | None -> ""
    | Some (name,email) ->
        String.concat "" [
          {|  <div class="txt-align-center margin-block-double full-width">
    <a class="btn center" title="Email |};legacy_attribute name;
          {|" href="|};
          legacy_attribute ("mailto:\"" ^ name ^ "\" <" ^ email ^ ">");
          {|">
      |};legacy_img context "lifebuoy.svg" ["aria-hidden","true"];
          {|
      <span>|};legacy_text email;
          {|</span>
</a>
    <div class="txt-align-center center margin-block txt-subtle">Campfire&trade; version <span class="version-badge">|};
          legacy_text context.app_version;
          {|</span></div>
  </div>
|}] in
  String.concat "" [
    {|<section class="txt-align-center">
  <div class="panel |};
    (if Option.is_some context.flash_alert then "shake" else "");
    {|">
    <figure class="account-logo avatar center margin-block-end txt-xx-large">|};
    legacy_img ~size:(Some 300) context context.logo_url ["alt","Account logo"];
    {|</figure>

    <form class="flex flex-column gap" action="|};
    legacy_attribute (context.base_url ^ "/session");
    {|" accept-charset="UTF-8" method="post">
      <fieldset class="flex flex-column gap center-block upad">
        <legend class="txt-large txt-align-center"><strong>|};
    legacy_text context.account_name;
    {|</strong></legend>

|};
    field "email_address" "email" "Enter your email address"
      {|autofocus="autofocus" autocomplete="username"|} "email";
    {|

|};
    field "password" "password" "Enter your password"
      {|autocomplete="current-password"|} "password";
    {|

        <button name="log_in" type="submit" class="btn btn--reversed center txt-large">
          |};
    legacy_img context "arrow-right.svg" ["aria-hidden","true"];
    {|
          <span class="for-screen-reader">Go</span>
</button>      </fieldset>
</form>  </div>

  |};help;
    {|
</section>
|}]

let session_new ~context ?email_address ?help_contact:contact () =
  legacy_session_page ~context
    ~content:(legacy_session_content ~context ?email_address ?contact ())

let first_run ~context () =
  let icon name = void "img" ["aria-hidden","true";
    "src",asset context (name ^ ".svg")] in
  let field ?translation key kind placeholder attrs icon_name =
    cls "div" "flex align-center gap" [
      translation_button context (Option.value translation ~default:key);
      cls "label" "flex align-center gap flex-item-grow txt-large input input--actor" [
        input ~required:true ~name:("user[" ^ key ^ "]") ~kind
          ~attrs:(["id","user_" ^ key;"class","input";
            "placeholder",placeholder] @ attrs) ();
        void "img" ["aria-hidden","true";"class","colorize--black";
          "src",asset context (icon_name ^ ".svg");
          "width","24";"height","24"]]] in
  let content = form ~attrs:["class","center max-width";
    "enctype","multipart/form-data";"accept-charset","UTF-8"] "/first_run"
    (cls "section" "nametag u-relative" [
      cls "div" "flex justify-center align-center pad-block" [
        void "img" ["class","nametag__lanyard";"aria-hidden","true";
          "src",asset context "lanyard.svg"]];
      cls "div" "nametag__inner flex flex-column gap" [
        cls "fieldset" "flex flex-column center-block" [
          elt "legend" ["class","txt-large txt-align-center"] [
            elt "strong" [] [text "Set up Campfire"]];
          elt "label" ["class","align-center center avatar__form gap";
            "data-controller","upload-preview"] [
            cls "div" "btn input--file" [icon "camera";
              input ~name:"user[avatar]" ~kind:"file"
                ~attrs:["id","user_avatar";"class","input";"accept","image/*";
                  "data-upload-preview-target","input";
                  "data-action","upload-preview#previewImage"] ();
              cls "span" "for-screen-reader" [text "Add your avatar"]];
            cls "div" "btn avatar input--file txt-xx-large" [
              void "img" ["aria-hidden","true";
                "data-upload-preview-target","image";
                "alt","Add your avatar";
                "src",asset context "default-avatar.svg"];
              cls "span" "for-screen-reader" [text "Avatar"]]]];
        field ~translation:"user_name" "name" "text" "Name"
          ["autocomplete","name";"autofocus","autofocus";
            "data-1p-ignore","true"] "person";
        field "email_address" "email" "Email address"
          ["autocomplete","username"] "email";
        field "password" "password" "Password"
          ["autocomplete","new-password";"maxlength","72";"size","72"]
          "password";
        elt "button" ["name","button";"type","submit";
          "class","btn btn--reversed center txt-large"] [icon "arrow-right";
          cls "span" "for-screen-reader" [text "Save"]]]]) in
  page ~title:"Set up Campfire" ~body_class:"signup" ~context content

let welcome ~context () =
  let current_user_name = match context.current_user with
    | None -> "" | Some user -> user.name in
  let content = elt "div" ["id","message-area";"class","message-area"] [
    cls "div" "message-area--empty min-width center" [
      cls "figure" "center pad" [
        void "img" ["aria-hidden","true";
          "class","colorize--black translucent";
          "src",asset context "messages-empty.svg"];
        cls "span" "for-screen-reader" [text current_user_name]]]] in
  let sidebar = elt "turbo-frame" ["id","user_sidebar";
    "src",Route_helpers.user_sidebar ();
    "target","_top";"data-turbo-permanent","true";
    "data-controller","rooms-list read-rooms turbo-frame";
    "data-rooms-list-unread-class","unread";
    "data-action","presence:present@window->rooms-list#read read-rooms:read->rooms-list#read turbo:frame-load->rooms-list#loaded refresh-room:visible@window->turbo-frame#reload"] [] in
  page ~title:"No rooms yet" ~body_class:"sidebar" ~sidebar ~context content

type push_subscription = {
  id:int64; endpoint:string; browser:string; version:string; platform:string
}
let push_subscriptions_index ~context ?last_room_id ~push_subscriptions () =
  let icon name = void "img" ["aria-hidden","true";
    "src",asset context (name ^ ".svg");"width","20";"height","20"] in
  let back_path = match last_room_id with
    | Some id -> relative_room id | None -> "/" in
  let nav = cls "div" "flex-item-justify-start" [
    elt "a" ["class","btn";"href",back_path] [icon "arrow-left";
      cls "span" "for-screen-reader" [text "Go Back"]]] in
  let push_subscription_item subscription =
    let path=Route_helpers.user_push_subscription (i64 subscription.id) in
    let action_button ?(delete=false) action class_name icon_name label =
      form ~attrs:["class","button_to"] action (concat [
        (if delete then input ~name:"_method" ~kind:"hidden"
          ~value:"delete" () else concat []);
        elt "button" ["class",class_name;"type","submit"] [
          icon icon_name;cls "span" "for-screen-reader" [text label]]]) in
    elt "li" ["class","flex flex-column margin-none membership-item"] [
      cls "span" "overflow-ellipsis txt-primary txt-undecorated" [
        elt "strong" [] [text (subscription.browser ^ " " ^
          subscription.version ^ " on " ^ subscription.platform)];
        void "br" []];
      cls "span" "flex align-start gap txt-small" [
        elt "span" [] [text subscription.endpoint];
        cls "span" "flex align-center gap" [
          action_button (Route_helpers.user_push_subscription_test_notifications
            (i64 subscription.id)) "btn btn--reversed"
            "notification-bell-everything" "Send test notification";
          action_button ~delete:true path "btn btn--negative"
            "minus" "Delete subscription"]]] in
  let content = cls "section" "panel panel--wide flex flex-column gap" [
    cls "h1" "txt-align-center txt-large margin-none" [
      text "Push Notification Subscriptions"];
    elt "div" ["class","pad-inline fill-shade border-radius";
      "id","push_subscriptions"] [
      cls "menu" "pad flex flex-column gap"
        (List.map push_subscription_item push_subscriptions)]] in
  page ~title:"Push notification subscriptions" ~context ~nav content

let user_row (user:user) = elt "li" ["id","user_"^i64 user.id] [
  image ~width:40 ~height:40 user.avatar_url;
  a (relative_user user.id) [text user.name];text (" — " ^ user.role)]
let account_edit ~context ~join_code ~restrict_room_creation ~users =
  let checked = if restrict_room_creation then ["checked","checked"] else [] in
  page ~title:"Account settings" ~context (cls "section" "settings" [
    elt "h1" [] [text "Account settings"];
    form ~method_:"post" "/account" (concat [
      input ~name:"_method" ~kind:"hidden" ~value:"patch" ();
      elt "label" [] [text "Name";input ~name:"account[name]" ~kind:"text"
        ~value:context.account_name ()];
      elt "label" [] [input ~name:"account[settings][restrict_room_creation_to_administrators]"
        ~kind:"checkbox" ~attrs:checked ();text "Only administrators can create rooms"];
      button "Save changes"]);
    elt "section" [] [elt "h2" [] [text "Members"];
      elt "ul" [] (List.map user_row users)];
    elt "p" [] [text "Invite link code: ";elt "code" [] [text join_code];
      a ("/join/" ^ Uri.pct_encode join_code) [text "Invite someone"]]])

type account_member = { user:user; status:string }

let account_user_item ~context ({user;status}:account_member) =
  let icon name = void "img" ["aria-hidden","true";
    "src",asset context (name ^ ".svg");"width","20";"height","20"] in
  let current=match context.current_user with
    | Some viewer -> viewer.id=user.id | None -> false in
  let admin=match context.current_user with
    | Some viewer -> viewer.role="administrator" | None -> false in
  let active=status="active" in
  let action="/account/users/" ^ i64 user.id in
  elt "li" ["class","flex align-center gap margin-none " ^
    (if status="banned" then "banned" else "")] [
    elt "figure" ["class","avatar flex-item-no-shrink";
      "style","--avatar-size: 3.75ch;"] [
      elt "a" ["title",user.title;"class","btn avatar";
        "data-turbo-frame","_top";"href",relative_user user.id] [
        void "img" ["aria-hidden","true";"loading","lazy";
          "src",user.avatar_url;"width","48";"height","48"]]];
    cls "div" "min-width" [cls "div" "overflow-ellipsis fill-shade" [
      elt "strong" [] [text user.name]]];
    void "hr" ["class","separator";"aria-hidden","true"];
    (if admin && active && user.role<>"bot" then
      elt "form" ["data-controller","form";"action",action;
        "accept-charset","UTF-8";"method","post"] [
        input ~name:"_method" ~kind:"hidden" ~value:"patch" ();
        elt "label" ["class","btn txt-small flex-item-no-shrink";
          "for","role_user_" ^ i64 user.id] [
          cls "span" "for-screen-reader" [text
            ("Role: " ^ (if user.role="administrator" then "Administrator" else "Member"))];
          icon "crown";
          void "input" (["name","user[role]";"type","hidden";
            "value","member"] @ if current then ["disabled","disabled"] else []);
          void "input" (["data-action","form#submit";
            "hidden","hidden";"id","role_user_" ^ i64 user.id;
            "type","checkbox";"value","administrator";
            "name","user[role]"] @
            (if current then ["disabled","disabled"] else []) @
            (if user.role="administrator" then ["checked","checked"] else []))]]
     else concat []);
    (if admin && active && not current then
      elt "form" ["class","button_to";"method","post";
        "action",action] [
        input ~name:"_method" ~kind:"hidden" ~value:"delete" ();
        elt "button" ["class","btn txt-small flex-item-no-shrink btn--negative";
          "data-turbo-confirm","Are you sure you want to permanently remove this person from the account? This can’t be undone.";
          "type","submit"] [icon "minus";
          cls "span" "for-screen-reader" [text ("Delete " ^ user.name)]]]
     else concat []);
    (if current then elt "a" ["class","btn txt-small flex-item-no-shrink";
      "target","_top";"href","/users/me/profile"] [
        icon "pencil";cls "span" "for-screen-reader" [text "My settings"]]
     else concat [])]

let account_next_page page =
  elt "turbo-frame" ["id","next_page_container";"loading","lazy";
    "src","/account/users.turbo_stream?page=" ^ Uri.pct_encode page;
    "class","flex center"] [cls "div" "spinner center" []]

let account_users_page_stream ~context ~users ?next_page () =
  render (concat [
    elt "turbo-stream" ["action","replace";"target","next_page_container"] [
      elt "template" [] (List.map (account_user_item ~context) users)];
    (match next_page with None -> concat [] | Some page ->
      elt "turbo-stream" ["action","append";"target","account_users"] [
        elt "template" [] [account_next_page page]])])

let account_edit_page ~context ?last_room_id ~account_id ~join_code
    ~restrict_room_creation ~administrators ~members ?next_page () =
  let icon ?(size=20) ?(attrs=[]) name =
    void "img" (attrs @ ["src",asset context (name ^ ".svg");
      "width",string_of_int size;"height",string_of_int size]) in
  let back=match last_room_id with
    | Some id -> relative_room id | None -> "/" in
  let nav=concat [
    cls "div" "flex-item-justify-start" [
      elt "a" ["class","btn";"href",back] [
        icon ~attrs:["aria-hidden","true"] "arrow-left";
        cls "span" "for-screen-reader" [text "Go Back"]]];
    (match context.current_user with
    | Some user when user.role="administrator" ->
      cls "div" "flex align-center gap flex-item-justify-end" [
        elt "a" ["class","btn";"style","view-transition-name: chat-bots";
          "href","/account/bots"] [icon ~attrs:["aria-hidden","true"] "bot";
          cls "span" "for-screen-reader" [text "Set up chat bots"]];
        elt "a" ["class","btn";"style","view-transition-name: custom-styles";
          "href","/account/custom_styles/edit"] [
          icon ~attrs:["aria-hidden","true"] "art";
          cls "span" "for-screen-reader" [text "Custom styles"]]]
    | _ -> concat [])] in
  let action="/account." ^ i64 account_id in
  let account_form ?(attrs=[]) ?(multipart=false) method_ content =
    elt "form" (attrs @ ["data-controller","form"] @
      (if multipart then ["enctype","multipart/form-data"] else []) @
      ["action",action;"accept-charset","UTF-8";"method","post"]) [
      input ~name:"_method" ~kind:"hidden" ~value:method_ ();
      content] in
  let logo_field label_class =
    elt "label" ["class",label_class] [
      (if label_class="btn input--file" then
        icon ~attrs:["aria-hidden","true"] "camera"
      else void "img" ["role","presentation";
        "data-upload-preview-target","image";
        "src",context.logo_url;"width","48";"height","48"]);
      void "input" ["class","input";"accept","image/*";
        "data-action","upload-preview#previewImage change->form#submit";
        "type","file";"name","account[logo]";"id","account_logo"];
      cls "span" "for-screen-reader" [text "Upload logo"]] in
  let can_admin=match context.current_user with
    | Some user -> user.role="administrator" | None -> false in
  let admin_settings=concat [
    elt "div" ["class","align-center center avatar__form gap";
      "data-controller","upload-preview"] [
      account_form ~attrs:["class","txt--medium"] ~multipart:true
        "patch" (logo_field "btn input--file");
      account_form ~multipart:true "patch"
        (logo_field "btn avatar input--file account-logo txt-xx-large");
      (if context.has_custom_logo then
        elt "form" ["class","button_to";"method","post";
          "action",context.logo_url] [
          input ~name:"_method" ~kind:"hidden" ~value:"delete" ();
          elt "button" ["class","btn btn--negative txt-small avatar__delete-btn";
            "type","submit"] [icon ~attrs:["aria-hidden","true"] "minus";
            cls "span" "for-screen-reader" [text "Delete logo"]]]
      else concat [])];
    account_form ~attrs:["class","flex flex-column gap"] "patch" (
      cls "div" "flex align-center gap" [
        translation_button context "account_name";
        cls "label" "flex align-center gap flex-item-grow" [
          void "input" ["class","input txt-large";"autocomplete","off";
            "placeholder","Name this account";"autofocus","autofocus";
            "data-action","keydown.enter->form#submit";
            "type","text";"value",context.account_name;
            "name","account[name]";"id","account_name"]];
        elt "button" ["name","button";"type","submit";
          "class","btn btn--reversed center"] [
          icon ~attrs:["aria-hidden","true"] "check";
          cls "span" "for-screen-reader" [text "Save changes"]]]);
    cls "div" "margin-block-start pad-block pad-inline-double fill-shade border-radius" [
      account_form ~attrs:["class","flex align-center gap center"] "put" (
        concat [
          cls "div" "flex-item-grow flex align-center gap txt-align-start" [
            icon ~size:18 ~attrs:["class","colorize--black";
              "aria-hidden","true"] "crown";
            text " Must be admin to create new rooms"];
          void "input" ["value",string_of_bool (not restrict_room_creation);
            "type","hidden";
            "name","account[settings][restrict_room_creation_to_administrators]";
            "id","account_settings_restrict_room_creation_to_administrators"];
          cls "label" "switch" [
            void "input" (["type","checkbox";"class","switch__input";
              "data-action","change->form#submit"] @
              if restrict_room_creation then ["checked","checked"] else []);
            cls "span" "switch__btn round" [];
            cls "span" "for-screen-reader" [
              text "Must be admin to create new rooms"]]])]] in
  let visible_users=concat [
    concat (List.map (account_user_item ~context) administrators);
    (if administrators<>[] && members<>[] then
      void "hr" ["class","separator full-width";
        "style","--border-style: solid"] else concat []);
    concat (List.map (account_user_item ~context) members);
    (match next_page with None -> concat [] | Some page ->
      account_next_page page)] in
  let content=elt "section" ["class","panel txt-align-center flex flex-column gap";
    "style","view-transition-name: account-settings"] [
    (if can_admin then admin_settings else concat [
      elt "figure" ["class","account-logo avatar txt-xx-large center"] [
        image ~alt:"Account logo" ~width:300 ~height:300 context.logo_url];
      cls "h1" "flex-item-grow txt-x-large" [text context.account_name]]);
    cls "div" "margin-block pad-inline pad-block-start fill-shade border-radius" [
      invite_fragment context join_code;
      void "hr" ["class","margin-block separator full-width";
        "style","--border-style: solid"];
      cls "menu" "flex flex-column gap margin-none pad" [
        id "turbo-frame" "account_users" [visible_users]]]] in
  let footer=cls "div" "txt-align-center center margin-block-double txt-subtle" [
    text "Campfire™ version ";
    cls "span" "version-badge" [text context.app_version]] in
  page ~title:"Account settings" ~context ~nav ~footer content
let join_new_with ~context ~join_code ?help_contact () =
  let icon ?(size=None) ?(attributes=[]) name =
    void "img" (attributes @ ["src",asset context name] @
      match size with None -> [] | Some size ->
        ["width",string_of_int size;"height",string_of_int size]) in
  let nav=cls "div" "flex-item-justify-end" [
    elt "a" ["class","btn flex-item-justify-end";
      "href",Route_helpers.new_session ()] [
      icon "login-keys.svg" ~attributes:["aria-hidden","true"];
      cls "span" "for-screen-reader" [text "Sign in"]]] in
  let field key kind placeholder attrs =
    cls "div" "flex align-center gap" [
      translation_button context
        (if key="name" then "user_name" else key);
      cls "label" "flex align-center gap flex-item-grow txt-large input input--actor" [
        void "input" (["name","user[" ^ key ^ "]";
          "id","user_" ^ key;"class","input";
          "placeholder",placeholder;"type",kind;
          "required","required"] @ attrs);
        icon ~size:(Some 24)
          ~attributes:["aria-hidden","true";"class","colorize--black"]
          (match key with "name" -> "person.svg"
           | "email_address" -> "email.svg"
           | _ -> key ^ ".svg")]] in
  let logo=cls "figure" "account-logo avatar " [
    void "img" ["alt","Account logo";"src",context.logo_url;
      "width","300";"height","300"]] in
  let content=form ~attrs:["class","center";
    "enctype","multipart/form-data";"accept-charset","UTF-8"]
    (Route_helpers.join join_code) (cls "section" "nametag u-relative" [
      cls "div" "flex justify-center align-center pad-block" [
        icon "lanyard.svg" ~attributes:["class","nametag__lanyard";
          "aria-hidden","true"]];
      cls "div" "nametag__inner flex flex-column gap" [
        cls "fieldset" "flex flex-column center-block" [
          cls "legend" "txt-align-center flex gap" [
            logo;
            cls "strong" "txt-large" [text context.account_name]];
          elt "label" ["class","align-center center avatar__form gap";
            "data-controller","upload-preview"] [
            cls "div" "btn input--file" [
              icon "camera.svg" ~attributes:["aria-hidden","true"];
              void "input" ["name","user[avatar]";"id","user_avatar";
                "class","input";"type","file";"accept","image/*";
                "data-upload-preview-target","input";
                "data-action","upload-preview#previewImage"];
              cls "span" "for-screen-reader" [text "Upload avatar"]];
            cls "div" "btn avatar input--file txt-xx-large" [
              icon "default-avatar.svg" ~attributes:[
                "aria-hidden","true";"data-upload-preview-target","image"];
              cls "span" "for-screen-reader" [text "Avatar"]]]];
        field "name" "text" "Name"
          ["autocomplete","name";"autofocus","autofocus";
            "data-1p-ignore","true"];
        field "email_address" "email" "Email address"
          ["autocomplete","username"];
        field "password" "password" "Password"
          ["autocomplete","new-password";"maxlength","72";"size","72"];
        elt "button" ["name","button";"class","btn btn--reversed center txt-large";
          "type","submit"] [
          icon "check.svg" ~attributes:["aria-hidden","true"];
          cls "span" "for-screen-reader" [text "Save"]]]]) in
  let contact=match help_contact with None -> concat [] | Some (name,email) ->
    elt "div" ["class","txt-align-center margin-block-double full-width"] [
      elt "a" ["class","btn center";"title","Email " ^ name;
        "href","mailto:\"" ^ name ^ "\" <" ^ email ^ ">"] [
        icon "lifebuoy.svg" ~attributes:["aria-hidden","true"];
        elt "span" [] [text email]];
      cls "div" "txt-align-center center margin-block txt-subtle" [
        text "Campfire™ version ";
        cls "span" "version-badge" [text context.app_version]]] in
  page ~title:"Sign up" ~body_class:"signup" ~context ~nav
    (concat [content;contact])
let join_new ~context ~join_code =
  join_new_with ~context ~join_code ()
let session_transfer ~context ~transfer_id =
  let content = String.concat "" [
    "\n<form data-controller=\"auto-submit\" action=\"";
    legacy_attribute ("/session/transfers/" ^ transfer_id);
    "\" accept-charset=\"UTF-8\" method=\"post\">";
    "<input type=\"hidden\" name=\"_method\" value=\"put\" /></form>\n"] in
  legacy_page ~context ~title:"Campfire" ~body_class:""
    ~head:"" ~nav:"" ~content ~footer:"" ~sidebar:""
let bots_index ~context ~bots =
  let icon ?(size=None) ?(attributes=[]) name =
    void "img" (attributes @ ["src",asset context name] @
      match size with None -> [] | Some size ->
        ["width",string_of_int size;"height",string_of_int size]) in
  let nav=cls "div" "flex-item-justify-start" [
    elt "a" ["class","btn";"href","/account/edit"] [
      icon "arrow-left.svg" ~size:(Some 20)
        ~attributes:["aria-hidden","true"];
      cls "span" "for-screen-reader" [text "Go Back"]]] in
  let command_line ~icon_name ~label ~copy_label value =
    cls "div" "flex align-center gap" [
      icon icon_name ~size:(Some 24)
        ~attributes:["aria-hidden","true";"class","colorize--black"];
      cls "div" "flex-item-grow" [
        void "input" ["type","text";
          "class","input full-width fill-white";
          "value",value;"aria-label",label;"readonly",""]];
      cls "div" "txt-small" [
        elt "button" ["class","btn";"data-controller","copy-to-clipboard";
          "data-action","copy-to-clipboard#copy";
          "data-copy-to-clipboard-success-class","btn--success";
          "data-copy-to-clipboard-content-value",value] [
          icon "copy-paste.svg" ~size:(Some 20)
            ~attributes:["aria-hidden","true"];
          cls "span" "for-screen-reader" [text copy_label]]]] in
  let bot_item ((bot:user), rooms) =
    elt "li" ["class","flex flex-column gap flush fill-shade border-radius pad-block pad-inline-double"] [
      cls "div" "flex align-center gap" [
        elt "figure" ["class","avatar flex-item--no-shrink";
          "style","--avatar-size: 2.65em;"] [
          elt "a" ["class","btn avatar";"data-turbo-frame","_top";
            "href",relative_user bot.id;"title",bot.name] [
            void "img" ["aria-hidden","true";"loading","lazy";
              "src",bot.avatar_url;"width","48";"height","48"]]];
        cls "div" "min-width" [
          cls "div" "overflow-ellipsis txt-large" [
            elt "strong" [] [text bot.name]]];
        elt "a" ["class","btn flex-item-justify-end";
          "style","view-transition-name: chat-bot-" ^ i64 bot.id;
          "href","/account/bots/" ^ i64 bot.id ^ "/edit"] [
          icon "pencil.svg" ~size:(Some 20)
            ~attributes:["aria-hidden","true"];
          cls "span" "for-screen-reader" [text ("Edit " ^ bot.name)]]];
      concat (List.map (fun (name,path) ->
        let endpoint=if String.starts_with ~prefix:"http" path then path
          else context.base_url ^ path in
        elt "fieldset" ["class","gap max-width pad border border-radius"] [
          cls "legend" "min-width txt-align-start pad-inline" [
            cls "strong" "overflow-ellipsis" [text name]];
          command_line ~icon_name:"messages-outlined.svg"
            ~label:"curl command for posting messages"
            ~copy_label:"Copy message command"
            ("curl -d 'Hello!' " ^ endpoint);
          command_line ~icon_name:"attachment.svg"
            ~label:"curl command for posting attachments"
            ~copy_label:"Copy attachment command"
            ("curl -F \"attachment=@/path/to/file\" " ^ endpoint)]) rooms)] in
  let content=elt "section" [
    "class","panel panel--wide txt-align-center flex flex-column position-relative";
    "style","view-transition-name: chat-bots"] [
    cls "div" "flex align-center gap" [
      cls "div" "panel__button" [translation_button context "chat_bots"];
      cls "div" "pad-inline-double center" [
        cls "h1" "margin-none" [text "Chat bots"];
        cls "p" "margin-none-block-start" [
          text "With Chat bots, other sites and services can post updates directly to Campfire."];
        elt "a" ["class","btn btn--reversed txt-large";
          "aria-label","Add a chat bot";"href","/account/bots/new"] [
          icon "bot.svg" ~size:(Some 20)
            ~attributes:["aria-hidden","true"];
          icon "add.svg" ~size:(Some 20)
            ~attributes:["aria-hidden","true"]]]];
    elt "div" ["class","pad-inline pad-block-start "] [
      elt "menu" ["class","flex flex-column gap margin-none pad"]
        (List.map bot_item bots)]] in
  page ~title:"Chat bots" ~context ~nav content
let bot_form_page ~context ?bot_id ?name ?webhook_url
    ?avatar_attachment_url () =
  let icon ?(size=None) ?(attributes=[]) name =
    void "img" (attributes @ ["src",asset context name] @
      match size with None -> [] | Some size ->
        ["width",string_of_int size;"height",string_of_int size]) in
  let nav=cls "div" "flex-item-justify-start" [
    elt "a" ["class","btn";"href","/account/bots"] [
      icon "arrow-left.svg" ~size:(Some 20)
        ~attributes:["aria-hidden","true"];
      cls "span" "for-screen-reader" [text "Go Back"]]] in
  let action=match bot_id with None -> "/account/bots" | Some id ->
    "/account/bots/" ^ i64 id in
  let field ?translation key kind placeholder attrs icon_name =
    cls "div" "flex align-center gap" [
      translation_button context (Option.value translation ~default:key);
      cls "label" "flex align-center gap flex-item-grow txt-large input input--actor" [
        void "input" (["name","user[" ^ key ^ "]";
          "id","user_" ^ key;"class","input";
          "type",kind;"placeholder",placeholder] @ attrs);
        icon icon_name ~size:(Some 24)
          ~attributes:["aria-hidden","true";"class","colorize--black"]]] in
  let inner=concat [
    (match bot_id with None -> concat [] | Some _ ->
      input ~name:"_method" ~kind:"hidden" ~value:"patch" ());
    cls "h1" "for-screen-reader" [text "Chat Bot Setup"];
    elt "label" ["class","align-center center avatar__form gap";
      "data-controller","upload-preview"] [
      cls "div" "btn input--file" [
        icon "camera.svg" ~size:(Some 20)
          ~attributes:["aria-hidden","true"];
        void "input" ["name","user[avatar]";"id","user_avatar";
          "class","input";"type","file";"accept","image/*";
          "data-upload-preview-target","input";
          "data-action","upload-preview#previewImage"];
        cls "span" "for-screen-reader" [text "Upload bot avatar"]];
      elt "div" ["class","avatar input--file txt-xx-large";
        "style","--avatar-size: var(--btn-size);"] [
        icon (Option.value avatar_attachment_url
          ~default:"default-bot-avatar.svg")
          ~size:(Some 48)
          ~attributes:["alt","Bot avatar";
            "data-upload-preview-target","image"]]];
    field ~translation:"bot_name" "name" "text" "Name the bot"
      (["autocomplete","name";"autofocus","autofocus";
        "required","required";"data-1p-ignore","true"] @
       match name with None -> [] | Some value -> ["value",value])
      "bot.svg";
    field "webhook_url" "url" "Webhook URL"
      (match webhook_url with None -> [] | Some value -> ["value",value])
      "web.svg";
    elt "button" ["class","btn btn--reversed center txt-large";
      "type","submit"] [
      icon "check.svg" ~size:(Some 20)
        ~attributes:["aria-hidden","true"];
      cls "span" "for-screen-reader" [text "Save changes"]]] in
  let bot_form=form ~attrs:["class","flex flex-column gap";
    "enctype","multipart/form-data";"accept-charset","UTF-8"]
    action inner in
  let destructive=match bot_id with None -> concat [] | Some id ->
    let action="/account/bots/" ^ i64 id in
    let destructive_button ~path ~method_ ~class_name ~aria_label
        ~confirm icons =
      form ~attrs:["class","button_to"] path (concat [
        input ~name:"_method" ~kind:"hidden" ~value:method_ ();
        elt "button" ["class",class_name;"aria-label",aria_label;
          "data-turbo-confirm",confirm;"type","submit"]
          (List.map (fun name ->
            icon name ~size:(Some 20)
              ~attributes:["aria-hidden","true"]) icons)]) in
    concat [
      void "hr" ["class","separator full-width margin-block-double"];
      cls "div" "flex align-center gap justify-space-between" [
        destructive_button ~path:action ~method_:"delete"
          ~class_name:"btn txt--small btn--negative"
          ~aria_label:"Delete this chat bot"
          ~confirm:"Are you sure you want to permanently remove this bot from the account? This can’t be undone."
          ["trash.svg";"bot.svg"];
        destructive_button ~path:(action ^ "/key") ~method_:"put"
          ~class_name:"btn full-width txt--small btn--negative"
          ~aria_label:"Generate a new key"
          ~confirm:"Are you sure you want to change the bot key? All usage of this bot must be updated."
          ["refresh.svg";"key.svg"]]] in
  let content=elt "section" (["class","panel"] @
    match bot_id with None -> [] | Some id ->
      ["style","view-transition-name: chat-bot-" ^ i64 id])
    [bot_form;destructive] in
  page ~title:(if Option.is_some bot_id then "Edit bot" else "New chat bot")
    ~context ~nav content
let bot_form ~context ?bot ?webhook_url () =
  bot_form_page ~context
    ?bot_id:(Option.map (fun (user:user) -> user.id) bot)
    ?name:(Option.map (fun (user:user) -> user.name) bot)
    ?webhook_url ()
let custom_styles_edit ~context ~styles =
  let icon ?(size=20) name = void "img" ["aria-hidden","true";
    "src",asset context (name ^ ".svg");
    "width",string_of_int size;"height",string_of_int size] in
  let nav = cls "div" "flex-item-justify-start" [
    elt "a" ["class","btn";"href",Route_helpers.edit_account ()] [
      icon "arrow-left";
      cls "span" "for-screen-reader" [text "Go Back"]]] in
  let form_content=concat [
    input ~name:"_method" ~kind:"hidden" ~value:"patch" ();
    cls "div" "panel__button" [translation_button context "custom_styles"];
    cls "div" "pad-inline-double margin-inline" [
      cls "h1" "margin-none" [text "Custom CSS"];
      elt "p" ["class","flex flex-wrap align-center justify-center gap margin-none-block-start";
        "style","--column-gap: 0.5ch; --row-gap: 0"] [
        elt "span" [] [text "Add custom CSS styles."];
        void "img" ["class","flex-inline colorize--black";
          "aria-hidden","true";"src",asset context "alert.svg";
          "width","16";"height","16"];
        elt "span" [] [text "Use Caution: you could break things."]]];
    cls "label" "flex align-start gap flex-item-grow" [
      elt "textarea" ["class","input input--code txt--small";
        "placeholder","Add CSS styles…";"autocomplete","off";
        "spellcheck","false";"autocorrect","off";
        "autocapitalize","off";"rows","16";
        "name","account[custom_styles]";"id","account_custom_styles"] [text styles]];
    elt "button" ["name","button";"type","submit";
      "class","btn btn--reversed center txt-large"] [
      icon "check";cls "span" "for-screen-reader" [text "Save changes"]]] in
  let content=elt "section" [
    "class","panel panel--wide txt-align-center flex flex-column position-relative";
    "style","view-transition-name: custom-styles"] [
    form ~attrs:["class","flex flex-column gap";
      "data-controller","form";
      "data-action","keydown.ctrl+enter->form#submit keydown.meta+enter->form#submit";
      "accept-charset","UTF-8"]
      (context.base_url ^ Route_helpers.account_custom_styles ()) form_content] in
  page ~title:"Custom styles" ~context ~nav content
let user_show ~context ~user ~bio =
  page ~title:user.name ~context (cls "section" "profile" [
    image ~width:96 ~height:96 user.avatar_url;
    elt "h1" [] [text user.name];
    (match bio with None -> concat [] | Some value -> elt "p" [] [text value]);
    elt "p" [] [text user.role]])

let profile_transfer_fragment ~context ~(user:user) ~transfer_id =
  let url=context.base_url ^ "/session/transfers/" ^ transfer_id in
  let qr_path=Route_helpers.qr_code
    (Rails_format.urlsafe_encode ~pad:true url) in
  let current=match context.current_user with
    | Some viewer -> viewer.id=user.id | None -> false in
  let icon ?(size=20) ?(attrs=[]) name =
    void "img" (["aria-hidden","true"] @ attrs @
      ["src",asset context (name ^ ".svg");
       "width",string_of_int size;"height",string_of_int size]) in
  elt "fieldset" [] [
    cls "legend" "gap" [
      icon ~size:36 ~attrs:["class","colorize--black"] "laptop";
      icon ~size:36 ~attrs:["class","colorize--black"] "transfer";
      icon ~size:36 ~attrs:["class","colorize--black"] "mobile-phone"];
    cls "div" "flex flex-column gap" [
      (if current then elt "label" ["for","session_transfer_url";
        "class","for-screen-reader"] [
          text "Use this link to login automatically on another device"]
       else cls "div" "flex align-center gap justify-center" [
         icon ~size:16 ~attrs:["class","flex-item-no-shrink colorize--black"] "crown";
         elt "label" ["for","session_transfer_url"] [
           text "Share to get them back into their account"]]);
      void "input" ["type","text";"class","input";"value",url;
        "id","session_transfer_url";"readonly",""];
      cls "div" "flex align-center center gap" [
        elt "a" ["class","btn";"data-lightbox-target","image";
          "data-action","lightbox#open";
          "data-lightbox-url-value",qr_path;"href",qr_path] [
          cls "span" "for-screen-reader" [text "Show auto-login QR code"];
          icon ~attrs:["class","colorize--black"] "qr-code"];
        elt "button" ["class","btn";
          "data-controller","copy-to-clipboard";
          "data-action","copy-to-clipboard#copy";
          "data-copy-to-clipboard-success-class","btn--success";
          "data-copy-to-clipboard-content-value",url] [
          cls "span" "for-screen-reader" [text "Copy auto-login link"];
          icon ~attrs:["class","flex-item-no-shrink colorize--black"] "copy-paste"];
        elt "button" ["class","btn";"hidden","hidden";
          "data-controller","web-share";"data-action","web-share#share";
          "data-web-share-url-value",url;
          "data-web-share-text-value","This is your own private sign-in URL, DO NOT SHARE IT. Use it to sign-in on another device or if you get locked out.";
          "data-web-share-title-value","Your sign-in link"] [
          cls "span" "for-screen-reader" [text "Share auto-login link"];
          icon ~attrs:["class","flex-item-no-shrink colorize--black"] "share"]]]]

let user_show_page ~context ?(back_url="/") ~(user:user) ~email_address
    ~bio ~status ~transfer_id () =
  let admin=match context.current_user with
    | Some viewer -> viewer.role="administrator" | None -> false in
  let current=match context.current_user with
    | Some viewer -> viewer.id=user.id | None -> false in
  let active=status="active" in
  let icon name=void "img" ["aria-hidden","true";
    "src",asset context (name ^ ".svg");"width","20";"height","20"] in
  let nav=concat [
    cls "div" "flex-item-justify-start" [
      elt "a" ["class","btn";"href",back_url] [icon "arrow-left";
        cls "span" "for-screen-reader" [text "Go Back"]]];
    cls "div" "flex align-center gap flex-item-justify-end" [
      if current then elt "a" ["class","btn";"href","/users/me/profile"] [
        void "img" ["aria-hidden","true";"src",asset context "pencil.svg"];
        cls "span" "for-screen-reader" [text "Edit my profile"]]
      else concat []]] in
  let ping ~bot =
    let action="/rooms/directs?user_ids%5B%5D=" ^ i64 user.id in
    elt "form" ["class","button_to";"method","post";"action",action] [
      elt "button" ["class",if bot then "btn btn--primary full-width txt--large"
        else "btn btn--reversed full-width txt-large";"type","submit"] [
        void "img" ((if bot then [] else
          ["aria-hidden","true";"aria-label","Ping " ^ user.name]) @
          ["src",asset context "messages.svg"])]] in
  let ban =
    let banned=status="banned" in
    let confirmation=if banned then
      "Are you sure you want to remove the ban on this user?"
    else "Are you sure you want to ban this user? This will log them out, delete their messages, and block their IP addresses." in
    elt "form" ["class","button_to";"method","post";
      "action","/users/" ^ i64 user.id ^ "/ban"] [
      (if banned then input ~name:"_method" ~kind:"hidden" ~value:"delete" ()
       else concat []);
      elt "button" ["class",if banned then "btn btn--negative full-width"
        else "btn full-width";"data-turbo-confirm",confirmation;
        "type","submit"] [
        void "img" ["aria-hidden","true";
          "aria-label",(if banned then "Remove Ban " else "Ban ") ^ user.name;
          "src",asset context "cancel.svg"];
        elt "span" [] [text (if banned then "Remove ban" else "Ban " ^ user.name)]]]
  in
  let details=if user.role="bot" then
      cls "div" "pad-double--inline push--inline push--block-start" [
        if active then ping ~bot:true else
          elt "div" [] [text (user.name ^ " is no longer on this account")]]
    else if status="deactivated" then
      elt "div" [] [
        cls "h1" "txt-x-large margin-none" [text user.name];
        elt "div" [] [text (user.name ^ " is no longer on this account")]]
    else concat [
      elt "div" ["class","flex flex-column gap";
        "style","--row-gap: calc(var(--block-space) / 3)"] [
        cls "h1" "txt-x-large txt-tight-lines margin-none" [text user.name];
        (if admin then elt "div" [] [
          elt "a" ["href","mailto:" ^ email_address] [text email_address]]
         else concat []);
        elt "div" [] [text (Option.value bio ~default:"")]];
      (if active then concat [
        cls "div" "pad-inline-double margin-inline margin-block-start" [
          ping ~bot:false];
        (if admin then concat [void "hr" ["class","margin-block-start borderless"];
          profile_transfer_fragment ~context ~user ~transfer_id]
         else concat [])] else concat []);
      (if admin && not current then cls "div" "margin-block-start" [ban]
       else concat [])] in
  let content=cls "section" "panel txt-align-center" [
    cls "div" ("flex flex-column gap " ^
      (if status="banned" then "banned" else "")) [
      elt "div" ["class","avatar txt-xx-large center";
        "style","background: white"] [
        void "img" ["alt","Profile avatar";"class","avatar";
          "src",user.avatar_url]];
      details]] in
  page ~title:user.name ~context ~nav content
let profile_edit ~context ~user ~email_address ~bio ~transfer_url =
  let qr_path = "/qr_code/" ^ Rails_format.urlsafe_encode ~pad:true transfer_url in
  page ~title:user.name ~context (cls "section" "panel flex flex-column gap" [
    image ~width:96 ~height:96 user.avatar_url;
    elt "h1" [] [text user.name];
    form ~attrs:["data-controller","form"] (Route_helpers.user_profile ()) (concat [
      input ~name:"_method" ~kind:"hidden" ~value:"patch" ();
      elt "label" ["class","input input--actor"] [
        text "Name";input ~name:"user[name]" ~kind:"text" ~value:user.name
          ~attrs:["autocomplete","name";"required","required"] ()];
      elt "label" ["class","input input--actor"] [
        text "Email address";input ~name:"user[email_address]" ~kind:"email"
          ~value:email_address ~attrs:["autocomplete","username"] ()];
      elt "label" ["class","input input--actor"] [
        text "Password";input ~name:"user[password]" ~kind:"password"
          ~attrs:["autocomplete","new-password";"maxlength","72"] ()];
      elt "label" ["class","input input--actor"] [
        text "Bio";elt "textarea" ["name","user[bio]";"class","input txt-large";
          "rows","3";"maxlength","200"] [text (Option.value bio ~default:"")]];
      button ~attrs:["class","btn btn--reversed center txt-large"] "Save changes"]);
    elt "fieldset" [] [
      elt "label" ["for","session_transfer_url";"class","for-screen-reader"]
        [text "Use this link to login automatically on another device"];
      void "input" ["id","session_transfer_url";"type","text";"class","input";
        "readonly","readonly";"value",transfer_url];
      elt "a" ["href",qr_path;"class","btn";
        "data-lightbox-target","image";"data-action","lightbox#open";
        "data-lightbox-url-value",qr_path]
        [elt "span" ["class","for-screen-reader"] [text "Show auto-login QR code"]]]])
let user_json ~base_url ~(user:user) =
  Rails_format.encode (`Assoc ["id",`Intlit (i64 user.id);
    "name",`String user.name;"role",`String user.role;
    "avatar_url",`String (if String.starts_with ~prefix:"http" user.avatar_url
      then user.avatar_url else base_url ^ user.avatar_url)])

type mention_user = { user:user; sgid:string }
let mention_avatar (mention:mention_user) =
  let user=mention.user in
  elt "a" ["title",user.title;"class","btn avatar";
    "data-turbo-frame","_top";"href",relative_user user.id] [
    void "img" ["aria-hidden","true";"src",user.avatar_url;
      "width","48";"height","48"]]
let mention_fragment (mention:mention_user) =
  elt "span" ["class","mention";"sgid",mention.sgid] [
    mention_avatar mention;text (" " ^ mention.user.name)]
let action_text_content content =
  cls "div" "lexxy-content" [raw content]
let mailer_layout content =
  String.concat "" [
    "<!DOCTYPE html>\n<html>\n  <head>\n";
    "    <meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\" />\n";
    "    <style>\n      /* Email styles need to be inline */\n    </style>\n";
    "  </head>\n\n  <body>\n    ";
    render content;
    "\n  </body>\n</html>\n"]
let pwa_manifest_json ~context ~logo_url_small =
  let json value=Yojson.Safe.to_string (`String value) in
  let image_url name=json (context.base_url ^ asset context name) in
  let logo_small=json logo_url_small in
  let logo=json context.logo_url in
  String.concat "" [
    "{\n  \"name\": ";json context.account_name;
    ",\n  \"icons\": [\n    {\n      \"src\": ";logo_small;
    ",\n      \"type\": \"image/png\",\n      \"sizes\": \"192x192\"\n    },\n";
    "    {\n      \"src\": ";logo;
    ",\n      \"type\": \"image/png\",\n      \"sizes\": \"512x512\"\n    },\n";
    "    {\n      \"src\": ";logo;
    ",\n      \"type\": \"image/png\",\n      \"sizes\": \"512x512\",\n      \"purpose\": \"maskable\"\n    }\n";
    "  ],\n  \"start_url\": \"/\",\n  \"display\": \"standalone\",\n";
    "  \"scope\": \"/\",\n  \"description\": \"A chat app from the makers of Basecamp and HEY.\",\n";
    "  \"categories\": [\"social\", \"business\", \"productivity\"],\n";
    "  \"theme_color\": \"#ffffff\",\n  \"background_color\": \"#ffffff\",\n";
    "  \"shortcuts\": [\n    {\n      \"name\": \"New chat room\",\n";
    "      \"description\": \"Open Campfire and start a new chat room\",\n";
    "      \"url\": \"rooms/opens/new\",\n      \"icons\": [{ \"src\": ";
    image_url "add.svg";", \"sizes\": \"any\" }]\n    },\n";
    "    {\n      \"name\": \"My profile\",\n";
    "      \"description\": \"Open Campfire and view your profile\",\n";
    "      \"url\": \"/users/me/profile\",\n      \"icons\": [{ \"src\": ";
    image_url "person.svg";", \"sizes\": \"any\" }]\n    }\n  ],\n";
    "  \"screenshots\": [\n    {\n      \"src\": ";
    image_url "screenshots/android-chat.png";
    ",\n      \"sizes\": \"1080x2400\",\n      \"form_factor\": \"narrow\",\n";
    "      \"label\": \"Campfire is an installable, self-hosted group chat system.\"\n    },\n";
    "    {\n      \"src\": ";image_url "screenshots/android-sidebar.png";
    ",\n      \"sizes\": \"1080x2400\",\n      \"form_factor\": \"narrow\",\n";
    "      \"label\": \"Easily invite people. Make rooms. @mentions, DMs, and mobile support.\"\n    },\n";
    "    {\n      \"src\": ";image_url "screenshots/android-dark-mode.png";
    ",\n      \"sizes\": \"1080x2400\",\n      \"form_factor\": \"narrow\",\n";
    "      \"label\": \"Full support for dark mode, customizable to your brand.\"\n    }\n  ]\n}\n"]
type og_embed = {
  href:string option; image_url:string option;
  filename:string; description:string option; twitter_avatar:bool
}
let truncate_utf8 ~length value =
  let rec run byte chars =
    if chars>=length-1 || byte>=String.length value then byte
    else let lead=Char.code value.[byte] in
      let width=if lead land 0x80=0 then 1 else if lead land 0xE0=0xC0
        then 2 else if lead land 0xF0=0xE0 then 3 else 4 in
      run (min (String.length value) (byte+width)) (chars+1) in
  let count=let rec loop byte chars =
    if byte>=String.length value then chars else
      let lead=Char.code value.[byte] in
      let width=if lead land 0x80=0 then 1 else if lead land 0xE0=0xC0
        then 2 else if lead land 0xF0=0xE0 then 3 else 4 in
      loop (min (String.length value) (byte+width)) (chars+1) in
    loop 0 0 in
  if count<=length then value else
    String.sub value 0 (run 0 0) ^ "…"
let og_embed (embed:og_embed) =
  elt "figure" ["class","attachment attachment--content attachment--og"] [
    elt "actiontext-opengraph-embed" [] [
      cls "div" ("og-embed gap " ^
        (if embed.twitter_avatar then "og-embed--twitter-avatar" else "")) [
        cls "div" "og-embed__content" [
          cls "div" "og-embed__title" [
            let title=truncate_utf8 ~length:280 embed.filename in
            (match embed.href with Some href when href<>"" ->
              elt "a" ["rel","noreferrer";"target","_blank";
                "href",href] [text title]
             | _ -> text title)];
          cls "div" "og-embed__description" [text
            (truncate_utf8 ~length:560
              (Option.value embed.description ~default:""))]];
        (match embed.image_url with Some url ->
          cls "div" "og-embed__image" [
            void "img" ["src",url;"class","image center";"alt",""]]
        | None -> concat [])]]]
let mention_item (mention:mention_user) =
  let user=mention.user in
  elt "lexxy-prompt-item" ["search",user.name;"sgid",mention.sgid] [
    elt "template" ["type","menu"] [
      cls "span" "autocomplete__item flex align-center gap unpad" [
        mention_avatar mention;
        cls "span" "autocompletable__name" [text user.name]]];
    elt "template" ["type","editor"] [
      elt "span" ["class","mention";"sgid",mention.sgid] [
        mention_avatar mention;text (" " ^ user.name)]]]
let autocomplete_users users = concat (List.map mention_item users)
let autocomplete_users_json ~base_url users =
  Rails_format.encode (`List (List.map (fun (mention:mention_user) ->
    let user=mention.user in
    `Assoc ["name",`String (render (text user.name));
      "value",`Intlit (i64 user.id);
      "avatar_url",`String (if String.starts_with ~prefix:"http" user.avatar_url
        then user.avatar_url else base_url ^ user.avatar_url);
      "sgid",`String mention.sgid]) users))
let ban_button ~context ~(user:user) ~banned =
  let action=Route_helpers.user_ban (i64 user.id) in
  let confirmation=if banned then
    "Are you sure you want to remove the ban on this user?"
  else "Are you sure you want to ban this user? This will log them out, delete their messages, and block their IP addresses." in
  form ~attrs:["class","button_to"] action (concat [
    (if banned then input ~name:"_method" ~kind:"hidden"
      ~value:"delete" () else concat []);
    elt "button" ["class",(if banned then "btn btn--negative full-width"
      else "btn full-width");"data-turbo-confirm",confirmation;
      "type","submit"] [
      void "img" ["aria-hidden","true";
        "aria-label",(if banned then "Remove Ban " else "Ban ") ^ user.name;
        "src",asset context "cancel.svg"];
      elt "span" [] [text (if banned then "Remove ban"
        else "Ban " ^ user.name)]]])

let avatar_color user_id =
  let palette = [|"#AF2E1B";"#CC6324";"#3B4B59";"#BFA07A";"#ED8008";
    "#ED3F1C";"#BF1B1B";"#736B1E";"#D07B53";"#736356";"#AD1D1D";
    "#BF7C2A";"#C09C6F";"#698F9C";"#7C956B";"#5D618F";"#3B3633";
    "#67695E"|] in
  let crc = ref Int32.minus_one in
  String.iter (fun c ->
    crc := Int32.logxor !crc (Int32.of_int (Char.code c));
    for _ = 1 to 8 do
      crc := if Int32.logand !crc 1l = 1l then
        Int32.logxor (Int32.shift_right_logical !crc 1) 0xEDB88320l
      else Int32.shift_right_logical !crc 1
    done) (i64 user_id);
  let hash = Int32.lognot !crc |> Int64.of_int32 in
  let hash = Int64.logand hash 0xFFFFFFFFL in
  palette.(Int64.to_int (Int64.rem hash (Int64.of_int (Array.length palette))))
let avatar_svg ~user_id ~initials =
  let spacing = if String.length initials >= 3 then
    "textLength=\"85%\" lengthAdjust=\"spacingAndGlyphs\"" else "" in
  Printf.sprintf
    "<svg version=\"1.1\" xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\"\n  viewBox=\"0 0 512 512\" class=\"avatar\" aria-hidden=\"true\">\n  <defs>\n    <clipPath id=\"porthole\">\n      <circle cx=\"50%%\" cy=\"50%%\" r=\"50%%\" />\n    </clipPath>\n  </defs>\n\n  <g>\n    <rect width=\"100%%\" height=\"100%%\" rx=\"50\" fill=\"%s\" />\n\n    <text x=\"50%%\" y=\"50%%\" fill=\"#FFFFFF\"\n      text-anchor=\"middle\" dy=\"0.35em\"\n      %s\n      font-family=\"-apple-system, BlinkMacSystemFont, Segoe UI, Roboto, Helvetica, Arial, sans-serif\"\n      font-size=\"230\"\n      font-weight=\"800\"\n      letter-spacing=\"-5\">\n      %s\n    </text>\n  </g>\n</svg>\n"
    (avatar_color user_id) spacing (render (text initials))

type room_kind = Open | Closed | Direct
type room = { id:int64; kind:room_kind; name:string; updated_at_ms:int64 }
type sidebar_entry = { room:room; unread:bool; members:user list }
let room_kind_name = function Open -> "rooms_open" | Closed -> "rooms_closed" | Direct -> "rooms_direct"
let room_dom_id room prefix = prefix ^ "_" ^ room_kind_name room.kind ^ "_" ^ i64 room.id
let sidebar_shared_room (entry:sidebar_entry) = elt "a" [
  "id",room_dom_id entry.room "list";
  "data-rooms-list-target","room";
  "data-room-id",i64 entry.room.id;
  "data-badge-dot-target","unread";
  "data-sorted-list-target","item";
  "data-sorted-list-name",entry.room.name;
  "style","--column-gap: 0.5em";
  "class",("align-center gap room btn txt-nowrap" ^
    if entry.unread then " unread" else "");
  "href",relative_room entry.room.id] [
    cls "span" "overflow-ellipsis" [text entry.room.name]]
let sidebar_frame ~context ~rooms ?entries ?(placeholders=[]) ?(can_create_rooms=true)
    ~rooms_stream_name ~user_rooms_stream_name () =
  let entries = Option.value entries ~default:(List.map (fun room ->
    {room;unread=false;members=[]}) rooms) in
  let stream name = elt "turbo-cable-stream-source"
    ["channel","Turbo::StreamsChannel";"signed-stream-name",name] [] in
  let icon ?(size=20) ?(class_name="") ?(style="") name =
    let src = if String.starts_with ~prefix:"/" name then name
      else asset context name in
    void "img" (["src",src;"width",string_of_int size;
      "height",string_of_int size;"aria-hidden","true"] @
      (if class_name="" then [] else ["class",class_name]) @
      if style="" then [] else ["style",style]) in
  let first_name (user:user) = match String.split_on_char ' ' user.name with
    | first::_ -> first | [] -> user.name in
  let member_initials members =
    let initials = members |> List.map (fun (user:user) ->
    String.split_on_char ' ' user.name |> List.filter ((<>) "")
    |> List.filteri (fun i _ -> i < 3)
    |> List.map (fun part -> String.uppercase_ascii (String.sub part 0 1))
    |> String.concat "") in
    match List.rev initials with
    | [] -> ""
    | [one] -> one
    | [last;first] -> first ^ "+" ^ last
    | last::rest -> String.concat ", " (List.rev rest) ^ ", and " ^ last in
  let direct_link (entry:sidebar_entry) =
    let members = entry.members in
    let single = match members with [one] -> Some one | _ -> None in
    elt "a" ["id",room_dom_id entry.room "list";
      "class",(if entry.unread then "direct unread" else "direct");
      "data-rooms-list-target","room";
      "data-room-id",i64 entry.room.id;
      "data-badge-dot-target","unread";
      "data-sorted-list-target","item";
      "data-sorted-list-number",i64 entry.room.updated_at_ms;
      "href",relative_room entry.room.id] [
      (match single with
       | Some member -> cls "span" "avatar" [
           icon ~size:48 member.avatar_url]
       | None -> cls "div" "avatar__group"
           (members |> List.filteri (fun i _ -> i < 4) |> List.map (fun member ->
             cls "span" "avatar" [icon member.avatar_url])));
      cls "span" "direct__author flex align-center gap max-width min-width border-radius txt-small" [
        cls "span" "txt-nowrap overflow-ellipsis" [
          cls "span" "for-screen-reader" [text "Ping with"];
          text (match single with Some member -> first_name member
            | None -> member_initials members)]]] in
  let placeholder (user:user) =
    form ~attrs:["class","button_to"]
      (Route_helpers.rooms_directs () ^ "?user_ids%5B%5D=" ^ i64 user.id)
      (elt "button" ["type","submit";
        "class","direct borderless fill-transparent unpad"] [
        cls "span" "avatar" [void "img" ["src",user.avatar_url;
          "aria-hidden","true"]];
        cls "span" "direct__author flex align-center gap max-width min-width border-radius txt-small" [
          cls "span" "txt-nowrap overflow-ellipsis" [
            cls "span" "for-screen-reader" [text "Start a ping with"];
            text (first_name user)]]]) in
  let directs,shared = List.partition (fun entry -> entry.room.kind=Direct) entries in
  elt "turbo-frame" ["id","user_sidebar";"target","_top";
    "data-turbo-permanent","true";
    "data-controller","rooms-list read-rooms turbo-frame";
    "data-rooms-list-unread-class","unread";
    "data-action","presence:present@window->rooms-list#read read-rooms:read->rooms-list#read turbo:frame-load->rooms-list#loaded refresh-room:visible@window->turbo-frame#reload"] [
    stream rooms_stream_name;stream user_rooms_stream_name;
    elt "div" ["class","sidebar__container overflow-y overflow-hide-scrollbar";
      "data-controller","badge-dot";"data-badge-dot-unread-class","unread";
      "data-action","rooms-list:unread@window->badge-dot#update rooms-list:read@window->badge-dot#update turbo:submit-start->turbo-frame#unpermanize"] [
      elt "turbo-frame" ["id","direct_rooms_control";"target","_top"] [
        elt "div" ["class","directs gap overflow-x overflow-hide-scrollbar"] [
          elt "a" ["href",Route_helpers.new_rooms_direct ();
            "data-turbo-frame","_self";"class","direct direct__new"] [
            cls "span" "avatar avatar--icon" [
              icon ~class_name:"colorize--black" "messages-add.svg"];
            cls "span" "direct__author flex max-width min-width border-radius pad-inline-half" [
              cls "span" "for-screen-reader" [text "New"];
              cls "span" "txt-small overflow-clip" [text "Ping"]]];
          elt "div" ["id","direct_rooms";"contents","";
            "data-controller","sorted-list";
            "data-action","rooms-list:unread@window->sorted-list#updateItem"]
            (List.map direct_link directs);
          elt "div" ["contents",""] (List.map placeholder placeholders)]];
      cls "div" "rooms position-relative flex flex-column gap" [
        elt "div" ["id","shared_rooms";"contents","";
          "data-controller","sorted-list"] (List.map sidebar_shared_room shared);
        (if can_create_rooms then
          elt "a" ["href",Route_helpers.new_rooms_open ();
            "class","rooms__new-btn btn room align-center gap txt-reversed";
            "aria-label","New Chat Room"] [
            icon ~style:"view-transition-name: new-room" "add.svg"]
         else concat [])];
      elt "button" ["class","btn sidebar__toggle";
        "data-action","toggle-class#toggle"] [
        icon "menu.svg";
        cls "span" "for-screen-reader" [text "Open menu"]]];
    cls "div" "flex align-end sidebar__tools gap justify-end" [
      elt "a" ["href",Route_helpers.user_profile ();
        "class","btn avatar flex-item-no-shrink sidebar__tool"] [
        (match context.current_user with Some user ->
          icon ~size:48 ~style:("view-transition-name: avatar-" ^ i64 user.id)
            user.avatar_url | None -> concat []);
        cls "span" "for-screen-reader" [text "My Settings"]];
      elt "a" ["href",Route_helpers.edit_account ();
        "class","btn align-center gap txt-reversed sidebar__tool"] [
        icon ~style:"view-transition-name: account-settings" "settings.svg";
        cls "span" "for-screen-reader" [text "Account Settings"]]]]
let sidebar_page ~context ~rooms ?entries ?(placeholders=[]) ?(can_create_rooms=true)
    ~rooms_stream_name ~user_rooms_stream_name () =
  let frame=sidebar_frame ~context ~rooms ?entries ~placeholders
    ~can_create_rooms ~rooms_stream_name ~user_rooms_stream_name () in
  page ~context frame
let room_display_name ?self_name ~name ~direct ~other_names () =
  if not direct then Option.value name ~default:"" else
  match other_names with
  | [] -> Option.value self_name ~default:""
  | [one] -> one
  | [a;b] -> a ^ " and " ^ b
  | xs -> let rev = List.rev xs in
    String.concat ", " (List.rev (List.tl rev)) ^ ", and " ^ List.hd rev
let room_form ~context ?room ~kind ~(users:user list) () =
  let editing = Option.is_some room in
  let title = (if editing then "Edit " else "New ") ^
    (match kind with Open -> "room" | Closed -> "private room" | Direct -> "Ping") in
  let stem = match kind with Open -> "opens" | Closed -> "closeds" | Direct -> "directs" in
  let action = "/rooms/"^stem^(match room with None -> "" | Some r -> "/"^i64 r.id) in
  page ~title ~context (cls "section" "room-form" [
    elt "h1" [] [text title];
    form action (concat [
      (if editing then input ~name:"_method" ~kind:"hidden" ~value:"patch" ()
       else concat []);
      (if kind=Direct then concat [] else elt "label" [] [text "Name";
        input ~name:"room[name]" ~kind:"text"
          ?value:(Option.map (fun r -> r.name) room)
          ~attrs:["aria-label","Name this room";"placeholder","Name this room"] ()]);
      elt "fieldset" [] (List.map (fun (user:user) -> elt "label" [] [
        input ~name:"user_ids[]" ~kind:"checkbox" ~value:(i64 user.id) ();
        text user.name]) users);
      button "Save"])])

type room_form_data = {
  form_room_id:int64 option; form_room_name:string option;
  form_kind:room_kind; can_administer:bool;
  form_current_user_id:int64 option;
  form_users:user list; selected_users:user list; unselected_users:user list;
}
let room_form_page ~context ?last_room_id (data:room_form_data) =
  let icon ?(size=None) ?(attributes=[]) name =
    void "img" (attributes @ ["src",asset context name] @
      match size with None -> [] | Some size ->
        ["width",string_of_int size;"height",string_of_int size]) in
  let back_path=match last_room_id with
    | Some id -> relative_room id | None -> "/" in
  let nav=cls "div" "flex-item-justify-start" [
    elt "a" ["class","btn";"href",back_path] [
      icon ~size:(Some 20) ~attributes:["aria-hidden","true"] "arrow-left.svg";
      cls "span" "for-screen-reader" [text "Go Back"]]] in
  let is_closed=data.form_kind=Closed in
  let kind_path=if is_closed then "closeds" else "opens" in
  let other_path=if is_closed then "opens" else "closeds" in
  let action="/rooms/" ^ kind_path ^
    Option.fold ~none:"" ~some:(fun id -> "/" ^ i64 id) data.form_room_id in
  let type_change="/rooms/" ^ other_path ^
    (match data.form_room_id with None -> "/new" | Some id ->
      "/" ^ i64 id ^ "/edit") in
  let user_row ~selected (user:user) =
    let control=if not data.can_administer then concat [] else
      if is_closed then
        if data.form_room_id=None &&
           data.form_current_user_id=Some user.id then concat [
          input ~name:"user_ids[]" ~kind:"hidden" ~value:(i64 user.id) ();
          icon ~size:(Some 20)
            ~attributes:["class","colorize--black flex-item-no-shrink";
              "aria-hidden","true"] "check.svg"]
        else
          elt "label" ["class","switch flex-item-no-shrink"] [
            void "input" (["type","checkbox";"name","user_ids[]";
              "value",i64 user.id;"class","switch__input"] @
              if selected then ["checked","checked"] else []);
            cls "span" "switch__btn round" [];
            cls "span" "for-screen-reader"
              [text ("Give " ^ user.name ^ " access to this room")]]
      else icon ~size:(Some 20)
        ~attributes:["class","colorize--black flex-item-no-shrink";
          "aria-hidden","true"] "check.svg" in
    elt "li" ["class","flex align-center gap margin-none";
      "data-value",String.lowercase_ascii user.name] [
      elt "figure" ["class","avatar flex-item-no-shrink";
        "style","--avatar-size: 4ch;"] [
        elt "a" ["title",user.title;"class","btn avatar";
          "data-turbo-frame","_top";"href",relative_user user.id] [
          void "img" ["aria-hidden","true";"loading","lazy";
            "src",user.avatar_url;"width","48";"height","48"]]];
      cls "div" "min-width" [
        cls "div" "overflow-ellipsis fill-shade" [
          elt "strong" [] [text user.name]]];
      void "hr" ["class","separator";"aria-hidden","true"];
      control] in
  let separator=void "hr" ["class","separator full-width";
    "style","--border-style: solid"] in
  let everyone=elt "li" ["class","flex align-center gap margin-none"] [
    elt "figure" ["class","avatar flex-item-no-shrink";
      "style","--avatar-border-radius: 0; --avatar-size: 4ch;"] [
      icon ~attributes:["aria-hidden","true";
        "class","colorize--black";
        "style","background-color: transparent"] "everyone.svg";
      cls "span" "for-screen-reader" [text "Everyone"]];
    cls "div" "min-width" [
      cls "div" "overflow-ellipsis fill-shade" [
        elt "strong" [] [text "Everyone"]]];
    void "hr" ["class","separator";"aria-hidden","true"];
    (if data.can_administer then
       elt "a" ["class","btn--faux flex-inline";"tabindex","-1";
         "data-turbo-action","replace";"href",type_change] [
         elt "label" ["for","room_type";"class","switch"] [
           void "input" (["type","checkbox";"id","room_type";
             "class","switch__input"] @
             if is_closed then [] else ["checked","checked"]);
           cls "span" "switch__btn round" [];
           cls "span" "for-screen-reader" [text
             (if is_closed then "Give everyone access to this room"
             else "Give only some access to this room")]]]
     else concat [])] in
  let member_count=if is_closed then
    List.length data.selected_users + List.length data.unselected_users
    else List.length data.form_users in
  let search=if member_count<=20 then concat [] else
    void "input" ["type","search";"id","search";"autocorrect","off";
      "autocomplete","off";"data-1p-ignore","true";
      "class","input input--transparent full-width";
      "placeholder","Filter…";"data-action","input->filter#filter"] in
  let members=if is_closed then
    List.map (user_row ~selected:true) data.selected_users @
    (if data.selected_users<>[] && data.unselected_users<>[]
     then [separator] else []) @
    List.map (user_row ~selected:false) data.unselected_users
    else List.map (user_row ~selected:true) data.form_users in
  let menu=elt "menu" [
    "class","flex flex-column gap margin-none pad overflow-y constrain-height";
    "data-controller","filter";
    "data-filter-active-class","filter--active";
    "data-filter-selected-class","selected"] (
      (if not is_closed || data.can_administer then
        [everyone;separator] else []) @
      [search;elt "div" ["data-filter-target","list";"contents",""] members]) in
  let name_or_heading=if data.can_administer then concat [
    translation_button context "room_name";
    cls "label" "flex-item-grow txt-large" [
      void "input" (["name","room[name]";"id","room_name";
        "class","input full-width";"required","required";
        "autofocus","autofocus";"placeholder","Name the room";
        "data-turbo-permanent","true";
        "data-action","keydown.enter->form#submit:prevent";
        "type","text"] @
        match data.form_room_name with None -> [] | Some name ->
          ["value",name]);
      cls "span" "for-screen-reader" [text "Name this room"]]]
    else cls "h1" "flex-item-grow txt-x-large" [
      text (Option.value data.form_room_name ~default:"")] in
  let body=form ~attrs:["accept-charset","UTF-8"] action (concat [
    (match data.form_room_id with None -> concat [] | Some _ ->
      input ~name:"_method" ~kind:"hidden" ~value:"patch" ());
    cls "div" "flex align-center gap" [name_or_heading];
    void "hr" ["class","margin-block borderless"];
    cls "section" "room-access margin-block pad-inline fill-shade border-radius"
      [menu];
    (if data.can_administer then elt "button" [
      "name","button";"type","submit";
      "class","btn btn--reversed txt-large center"] [
      icon ~size:(Some 20) ~attributes:["aria-hidden","true"] "check.svg";
      cls "span" "for-screen-reader" [text "Save"]]
    else concat [])]) in
  let first=elt "section" ["class","panel txt-align-center";
    "style","view-transition-name: " ^
      (match data.form_room_id with None -> "new-room" | Some id ->
        "edit-room-" ^ i64 id)] [body] in
  let delete=match data.form_room_id with
    | None -> concat []
    | Some _ when not data.can_administer -> concat []
    | Some id ->
      let display_name=Option.value data.form_room_name ~default:"" in
      cls "section" "panel txt-align-center" [
        form ~attrs:["class","button_to"]
          (context.base_url ^ relative_room id) (concat [
          input ~name:"_method" ~kind:"hidden" ~value:"delete" ();
          elt "button" ["class","btn btn--negative max-width";
            "aria-label","Delete " ^ display_name;
            "data-turbo-confirm",
              "Are you sure you want to delete this room and all messages in it? This can’t be undone.";
            "type","submit"] [
            icon ~size:(Some 20) ~attributes:["aria-hidden","true"] "trash.svg";
            cls "span" "overflow-ellipsis" [text display_name]]])] in
  let title=match data.form_room_id with
    | None -> "New chat room"
    | Some _ -> "Edit settings for " ^
      Option.value data.form_room_name ~default:"" in
  page ~title ~context ~nav (concat [first;delete])
let autocomplete_picker_template context =
  elt "template" ["id","autocompletable-user"] [
    elt "div" ["class","autocomplete__pill max-width";
      "data-value","";"tabindex","0"] [
      void "img" ["class","avatar flex-item-no-shrink";
        "data-content","avatar";"src",""];
      elt "span" ["class","autocomplete-field__selected-value-text overflow-ellipsis flex-item-grow";
        "data-content","label"] [];
      elt "button" ["type","button";
        "data-action","autocomplete#remove:prevent";"data-value","";
        "tabindex","-1";"class","btn btn--plain txt-small translucent flex-item-no-shrink"] [
        void "img" ["aria-hidden","true";"class","colorize--black";
          "src",asset context "remove-circle.svg"];
        cls "span" "for-screen-reader" [text "Remove ";
          elt "span" ["data-content","screenReaderLabel"] []]]]]
let direct_new ~context =
  let picker_template = autocomplete_picker_template context in
  let frame = elt "turbo-frame" ["id","direct_rooms_control";"target","_top"] [
    cls "div" "directs directs--new flex flex-column gap" [
      form ~attrs:["class","flex gap flex-item-grow";
        "data-controller","form";"data-action","keydown.esc->form#cancel";
        "accept-charset","UTF-8"]
        "/rooms/directs" (concat [
          elt "a" ["href",Route_helpers.user_sidebar ();
            "class","btn flex-item-no-shrink";
            "data-turbo-frame","user_sidebar";
            "data-form-target","cancel"] [
            void "img" ["aria-hidden","true";"src",asset context "arrow-left.svg"];
            cls "span" "for-screen-reader" [text "Cancel changes"]];
          cls "section" "autocomplete__container unpad input input--actor" [
            elt "div" ["class","autocomplete__input input flex flex-wrap position-relative flex-item-grow";
              "data-controller","autocomplete";
              "data-autocomplete-url-value","/autocompletable/users"] [
              elt "select" ["name","user_ids[]";
                "data-autocomplete-target","select";
                "data-template-id","autocompletable-user";
                "multiple","true";"hidden","";
                "required",""] [];
              picker_template;
              void "input" ["autocomplete","off";"autocorrect","off";
                "data-1p-ignore","true";
                "class","autocomplete__input input flex flex-wrap position-relative";
                "data-autocomplete-target","input";
                "data-action","input->autocomplete#search keydown->autocomplete#didPressKey";
                "type","text";"name","rooms_direct[user_ids_input]";
                "id","rooms_direct_user_ids_input"]]];
          elt "button" ["name","button";"type","submit";
            "class","btn btn--reversed flex-item-no-shrink"] [
            void "img" ["aria-hidden","true";"src",asset context "check.svg"];
            cls "span" "for-screen-reader" [text "Start Ping"]]]);
      cls "span" "txt-small translucent pad-inline-half center"
        [text "Type names to ping someone…"]]] in
  page ~context frame

let direct_edit_page ~context ?last_room_id ~room_id ~display_name
    ~(users:user list) () =
  let back_path=match last_room_id with
    | Some id -> relative_room id | None -> "/" in
  let icon ?(attributes=[]) name =
    void "img" (attributes @ ["src",asset context name]) in
  let nav=cls "div" "flex-item-justify-start" [
    elt "a" ["class","btn";"href",back_path] [
      icon "arrow-left.svg" ~attributes:["aria-hidden","true";
        "width","20";"height","20"];
      cls "span" "for-screen-reader" [text "Go Back"]]] in
  let member (user:user)=cls "div" "member flex flex-column gap fill-shade pad border-radius" [
    elt "figure" ["class","avatar center";
      "style","--avatar-border-radius: 10ch; --avatar-size: 10ch;"] [
      elt "a" ["title",user.title;"class","btn avatar";
        "data-turbo-frame","_top";"href",relative_user user.id] [
        void "img" ["aria-hidden","true";"loading","lazy";
          "src",user.avatar_url;"width","48";"height","48"]]];
    elt "strong" [] [text user.name]] in
  let content=cls "div" "panel txt-align-center" [
    cls "section" "directs--edit margin-block-end" (List.map member users);
    form ~attrs:["class","button_to"]
      (context.base_url ^ "/rooms/directs/" ^ i64 room_id) (concat [
      input ~name:"_method" ~kind:"hidden" ~value:"delete" ();
      elt "button" ["class","btn btn--negative center";
        "aria-label","Delete Ping";
        "data-turbo-confirm",
          "Are you sure you want to delete this ping and all messages in it? This can’t be undone.";
        "type","submit"] [
        icon "trash.svg" ~attributes:["aria-hidden","true"];
        text "Ping"]])] in
  page ~title:("Edit settings for " ^ display_name)
    ~context ~nav content

type attachment = { filename:string; blob_path:string; download_path:string; preview_url:string option }
type media_dimension = Dimension_int of int | Dimension_float of float
type media_attachment = {
  preview_url:string; is_video:bool;
  width:media_dimension option; height:media_dimension option;
}
type sound_view = { url:string; image:(string * int * int) option; text:string option }
type content = Text of trusted_html | Sound of string * string option |
  Rich_sound of sound_view | Attachment of attachment |
  Media_attachment of attachment * media_attachment | Unrenderable
type boost = { id:int64; message_id:int64; content:string; all_emoji:bool; booster:user }
type message = {
  id:int64;client_message_id:string;room_id:int64;room_name:string;
  creator:user;created_at_iso:string;created_at_ms:int64;updated_at_ms:int64;
  all_emoji:bool;content:content;editable_body:string;boosts:boost list;
}
let message_dom_id message prefix =
  (if prefix="" then "message" else prefix^"_message") ^ "_" ^ message.client_message_id
let permalink message = relative_message message.room_id message.id
let global_asset name =
  try Assets.asset_path name with _ -> "/assets/" ^ name
let media_number = function
  | Dimension_int number -> string_of_int number
  | Dimension_float number -> Ruby_compat.float_to_s number
let media_float = function
  | Dimension_int number -> float_of_int number
  | Dimension_float number -> number
let media_half = function
  | Dimension_int number -> Dimension_int (number / 2)
  | Dimension_float number -> Dimension_float (number /. 2.)
let preview_dimensions (media:media_attachment) =
  match media.width,media.height with
  | Some width,Some height ->
    let w=media_float width and h=media_float height in
    if w<=1200. && h<=800. then Some (width,height) else
    let scale=min (1200. /. w) (800. /. h) in
    Some (Dimension_float (w *. scale),Dimension_float (h *. scale))
  | _ -> None
let media_container dimensions content = match dimensions with
  | None -> cls "div" "max-inline-size center overflow-clip" [content]
  | Some (width,height) ->
    let aspect_ratio=media_float width /. media_float height
      |> Ruby_compat.float_to_s in
    elt "div" ["class","max-inline-size center flex overflow-clip";
      "style","width: " ^ media_number (media_half width) ^
        "px; aspect-ratio: " ^ aspect_ratio ^ ";"] [content]
let message_presentation message = match message.content with
  | Text trusted -> raw trusted
  | Sound (url,label) -> elt "audio" ["controls","controls";"src",url] [
      text (Option.value label ~default:"Play sound")]
  | Rich_sound sound ->
      elt "div" ["class","sound";"data-controller","sound";
        "data-action","messages:play->sound#play";
        "data-sound-url-value",sound.url] [
        elt "button" ["class","btn btn--plain";
          "data-action","sound#play"] [text "🔊"];
        (match sound.image with
        | Some (url,width,height) -> void "img" [
            "width",string_of_int width;"height",string_of_int height;
            "class","align--middle";"src",url]
        | None -> text (Option.value sound.text ~default:""))]
  | Media_attachment (file,media) ->
      let dimensions=preview_dimensions media in
      if media.is_video then
        media_container dimensions (elt "video" [
          "src",file.blob_path;"poster",media.preview_url;
          "controls","controls";"preload","none";
          "width","100%";"height","100%";
          "class","message__attachment"] [])
      else
        let size=match dimensions with None -> []
          | Some (width,height) -> ["width",media_number width;
              "height",media_number height] in
        media_container dimensions (elt "a" [
          "class","flex";"data-lightbox-target","image";
          "data-action","lightbox#open";
          "data-lightbox-url-value",file.download_path;
          "href",file.blob_path] [
          void "img" (size @ ["class","message__attachment";
            "loading","lazy";"src",media.preview_url])])
  | Attachment file ->
      (match file.preview_url with
       | Some url -> a file.blob_path [image ~width:320 ~height:240
           ~alt:file.filename url]
       | None ->
         let file_img attributes =
           let encoded = render (void "img" attributes) in
           let length = String.length encoded in
           if length < 2 || String.sub encoded (length-2) 2 <> "/>"
           then failwith "unexpected Tyxml image rendering";
           Fragment (String.sub encoded 0 (length-2) ^ " />") in
         let icon name width = file_img ["aria-hidden","true";
           "src",global_asset name;"width",string_of_int width;
           "height",string_of_int width] in
         elt "div" ["class","flex-inline align-center gap-half"] [
           file_img ["class","colorize--black";"aria-hidden","true";
             "src",global_asset "common-file-text.svg";
             "width","22";"height","22"];
           elt "span" [] [text file.filename];
           elt "a" ["class","btn message__action-btn hide-in-ios-pwa";
             "style","--width: auto;";"href",file.download_path] [
             icon "download.svg" 20;
             elt "span" ["class","for-screen-reader"]
               [text ("Download "^file.filename)]];
           elt "button" ["class","btn message__action-btn";
             "style","--width: auto;";"data-controller","web-share";
             "data-action","web-share#share";
             "data-web-share-files-value",file.download_path] [
             icon "share.svg" 20;
             elt "span" ["class","for-screen-reader"]
               [text ("Share "^file.filename)]]])
  | Unrenderable -> elt "span" ["class","message--unrenderable"]
      [text "This message could not be displayed"]
let boost_item (boost : boost) = concat [
  elt "div" ["id","boost_" ^ i64 boost.id;
    "class","boost boost-item flex-inline postion--relative max-width align-center fill-white gap";
    "data-controller","boost-delete";
    "data-boost-delete-perform-class","boost--deleting";
    "data-boost-delete-reveal-class","expanded";
    "data-boost-delete-booster-id-value",i64 boost.booster.id] [
      cls "figure" "avatar boost__avatar flex-item-no-shrink" [
        elt "a" ["title",boost.booster.title;"class","btn avatar";
          "data-turbo-frame","_top";"href",relative_user boost.booster.id] [
          void "img" ["aria-label",boost.booster.name ^ " boosted " ^ boost.content;
            "src",boost.booster.avatar_url;"width","48";"height","48"]]];
      elt "span" ["role","button";
        "class",(if boost.all_emoji then "txt-small txt-medium" else "txt-small");
        "data-action","click->boost-delete#reveal keydown.enter->boost-delete#reveal:prevent";
        "data-boost-delete-target","content"] [text boost.content];
      form ~attrs:["class","button_to"]
        ("/messages/" ^ i64 boost.message_id ^ "/boosts/" ^ i64 boost.id)
        (concat [
          input ~name:"_method" ~kind:"hidden" ~value:"delete" ();
          elt "button" ["data-action","boost-delete#perform";
            "data-boost-delete-target","button";
            "class","btn btn--negative flex-item-justify-end boost__delete";
            "type","submit"] [
            void "img" ["aria-hidden","true";"src",global_asset "minus.svg";
              "width","20";"height","20"];
            cls "span" "for-screen-reader" [text "Delete this boost"]]])];
  elt "span" ["id","delete_boost_accessible_label";
    "class","for-screen-reader"] [text "Press enter to delete this boost"]]
let action_icon name = void "img" ["class","colorize--black";"aria-hidden","true";
  "src",global_asset name;"width","20";"height","20"]
let reactions = ["👍","Thumbs up";"👏","Clapping";"👋","Waving hand";
  "💪","Muscle";"❤️","Red heart";"😂","Face with tears of joy";
  "🎉","Party popper";"🔥","Fire"]
let quick_boost message (character,title) =
  form ~attrs:["data-turbo-frame",message_dom_id message "boosting";
    "data-action","popup#close";"accept-charset","UTF-8"]
    ("/messages/" ^ i64 message.id ^ "/boosts") (concat [
      input ~name:"boost[content]" ~kind:"hidden" ~value:character
        ~attrs:["id","boost_content"] ();
      elt "button" ["name","button";"type","submit";"title",title;
        "class","btn message__action-btn";"data-emoji",character] [
        cls "figure" "margin-none boost-character" [text character];
        cls "span" "for-screen-reader" [text title]]])
let message_actions message =
  let new_boost_path = "/messages/" ^ i64 message.id ^ "/boosts/new" in
  let quick = cls "div" "quick-boosts" (List.map (quick_boost message) reactions @ [
    elt "a" ["class","btn message__action-btn message__boost-btn";
      "data-turbo-frame",message_dom_id message "new_boost";
      "data-action","soft-keyboard#open popup#close";"href",new_boost_path] [
      action_icon "boost.svg";cls "span" "for-screen-reader" [text "New boost"]]]) in
  let share = match message.content with
    | Attachment file | Media_attachment (file,_) -> [
      elt "a" ["class","btn message__action-btn center full-width hide-in-ios-pwa";
        "title","Download";"aria-label","Download";"href",file.download_path] [
        action_icon "download.svg"];
      elt "button" ["class","btn message__action-btn center full-width";
        "data-controller","web-share";"data-action","web-share#share";
        "data-web-share-files-value",file.blob_path;
        "data-web-share-title-value",file.filename;
        "title","Share";"aria-label","Share"] [action_icon "share.svg"]]
    | _ -> [elt "button" ["class","btn message__action-btn center full-width";
        "data-action","reply#reply";"title","Reply";"aria-label","Reply"]
        [action_icon "reply.svg"]] in
  let grid = cls "div" "flex flex-wrap border-top margin-block-start-half pad-block-start-half message__actions-grid"
    (share @ [
      elt "button" ["class","btn message__action-btn center full-width";
        "title","Copy link";"aria-label","Copy link";
        "data-controller","copy-to-clipboard";
        "data-action","copy-to-clipboard#copy";
        "data-copy-to-clipboard-success-class","btn--success";
        "data-copy-to-clipboard-url-value",relative_at_message message.room_id message.id]
        [action_icon "link.svg"];
      elt "a" ["class","btn message__action-btn center full-width message__edit-btn";
        "data-turbo-frame",message_dom_id message "edit";
        "title","Edit";"aria-label","Edit";
        "href",relative_message message.room_id message.id ^ "/edit"]
        [action_icon "pencil.svg"]]) in
  elt "div" ["class","message__actions";
    "data-controller","soft-keyboard"] [
    elt "details" ["class","position-relative";"data-controller","popup";
      "data-action","keydown.esc->popup#close toggle->popup#toggle click@document->popup#closeOnClickOutside";
      "data-popup-orientation-top-class","popup-orientation-top"] [
      cls "summary" "btn message__action-btn message__options-btn" [
        action_icon "menu-dots-horizontal.svg";
        cls "span" "for-screen-reader" [text "Message options"]];
      elt "div" ["class","message__actions-menu border shadow";
        "data-popup-target","menu"] [quick;grid]]]
let message_boosts message =
  elt "turbo-frame" ["id",message_dom_id message "boosting"] [
    elt "div" ["class","boosts flex flex-wrap align-center gap full-width";
      "style","--column-gap: 0.4ch; --row-gap: 0";
      "data-controller","turbo-streaming";
      "data-action","turbo:submit-start->turbo-streaming#unsubscribe"] [
      elt "div" ["class","flex-inline flex-wrap gap";
        "id",message_dom_id message "boosts";
        "data-turbo-streaming-target","container"]
        (List.map boost_item message.boosts);
      elt "turbo-frame" ["id",message_dom_id message "new_boost"] [
        elt "div" ["class","flex-inline message__boost-inline";
          "data-controller","soft-keyboard"] [
          elt "a" ["class","boost__action txt-small btn";
            "action","soft-keyboard#open";
            "href","/messages/" ^ i64 message.id ^ "/boosts/new"] [
            void "img" ["aria-hidden","true";"src",global_asset "boost.svg";
              "width","20";"height","20"];
            cls "span" "for-screen-reader" [text "Add a boost"]]]]]]
let message_new_boost ~context ~message ~(user:user) =
  let boosts_path="/messages/" ^ i64 message.id ^ "/boosts" in
  elt "turbo-frame" ["id",message_dom_id message "new_boost"] [
    elt "div" ["class","boost flex-inline postion--relative max-width fill-white";
      "style","--column-gap: var(--inline-space-half)"] [
      elt "form" ["class","boost__form flex align-center gap expanded";
        "data-controller","form scroll-into-view";
        "data-turbo-frame",message_dom_id message "boosting";
        "data-action","keydown.esc->form#cancel";
        "action",boosts_path;"accept-charset","UTF-8";"method","post"] [
        elt "label" ["class","boost__form-label flex gap";
          "style","--column-gap: 0.7ch;";"role","button";
          "tabindex","0";"aria-label","Add a boost"] [
          cls "figure" "avatar boost__avatar flex-item-no-shrink" [
            elt "a" ["title",user.title;"class","btn avatar";
              "data-turbo-frame","_top";"href",relative_user user.id] [
              void "img" ["aria-hidden","true";"src",user.avatar_url;
                "width","48";"height","48"]];
            cls "span" "for-screen-reader" [text user.name]];
          void "input" ["autofocus","autofocus";"autocomplete","off";
            "autocorrect","off";"maxlength","16";"required","required";
            "pattern","\\S+.*";"data-boost-form-target","input";
            "class","input input--boost txt-small";"size","16";
            "type","text";"name","boost[content]"]];
        elt "button" ["name","button";"type","submit";
          "class","btn btn--reversed"] [
          void "img" ["aria-hidden","true";
            "src",asset context "check.svg"];
          cls "span" "for-screen-reader" [text "Submit"]];
        elt "a" ["data-turbo-frame",message_dom_id message "boosts";
          "data-form-target","cancel";"class","btn btn--negative";
          "href",boosts_path] [
          void "img" ["aria-hidden","true";
            "src",asset context "minus.svg"];
          cls "span" "for-screen-reader" [text "Cancel"]]]]]
let message_room_not_found =
  elt "turbo-frame" ["id","composer-frame"] [
    elt "span" ["class","composer__input input input--actor shake margin-block-end txt-negative txt-align-center";
      "style","--input-border-color: var(--color-negative)"] [
      elt "span" [] [text "This room was deleted."]]]
let display_iso iso =
  if String.length iso >= 19 then String.sub iso 0 19 ^ "Z" else iso
let message_item message =
  if message.content = Unrenderable then
    elt "div" ["id",message_dom_id message "";"class","message--unrenderable"]
      [text "This message could not be displayed"]
  else
    let link = relative_at_message message.room_id message.id in
    elt "div" ["id",message_dom_id message "";
      "class",(if message.all_emoji then "message message--emoji" else "message ");
      "data-controller","reply";"data-user-id",i64 message.creator.id;
      "data-message-id",i64 message.id;
      "data-message-timestamp",i64 message.created_at_ms;
      "data-message-updated-at",i64 message.updated_at_ms;
      "data-sort-value",i64 message.created_at_ms;
      "data-messages-target","message";"data-search-results-target","message";
      "data-refresh-room-target","message";"data-reply-composer-outlet","#composer"] [
      cls "h2" "message__day-separator" [
        elt "time" ["datetime",display_iso message.created_at_iso;
          "data-local-time-target","date"] []];
      cls "figure" "avatar message__avatar" [
        elt "a" ["title",message.creator.title;"class","btn avatar";
          "data-turbo-frame","_top";"href",relative_user message.creator.id] [
          void "img" ["aria-hidden","true";"src",message.creator.avatar_url;
            "width","48";"height","48"]]];
      elt "turbo-frame" ["id",message_dom_id message "edit"] [
        cls "div" "message__body" [cls "div" "message__body-content" [
          cls "div" "message__meta" [cls "h3" "message__heading" [
            elt "span" ["class","message__author";"title",message.creator.title] [
              elt "strong" ["data-reply-target","author"] [text message.creator.name]];
            elt "a" ["target","_top";"class","message__permalink";"href",link] [
              elt "time" ["class","message__timestamp";
                "datetime",display_iso message.created_at_iso;
                "data-local-time-target","time"] []];
            cls "span" "message__room" [elt "a" ["target","_top";
              "data-reply-target","link";"href",link] [text message.room_name]]];
          message_actions message];
          elt "div" ["id",message_dom_id message "presentation";"dir","auto";
            "data-reply-target","body";"data-messages-target","body"]
            [message_presentation message];
          message_boosts message]]]]
let message_index messages = concat (List.map message_item messages)
let message_show ~context:_ message = render (message_item message)
let message_edit ~context message =
  let icon name attributes=void "img" (attributes @ ["src",asset context name]) in
  let delete_button ?(center=false) () =
    elt "button" ["name","button";"type","submit";
      "class",("btn btn--negative" ^ if center then " center margin-block-end" else "");
      "form",message_dom_id message "delete_form";
      "data-turbo-confirm","Are you sure you want to delete this message?"] [
      icon "trash.svg" ["aria-hidden","true"];
      cls "span" "for-screen-reader" [text "Delete message"]] in
  let button_row buttons =
    cls "div" "message__edit-btns flex align-center justify-space-between gap full-width pad-block-start-half" buttons in
  let editor=elt "lexxy-editor" [
    "rows","1";"class","input lexxy-content";
    "aria-multiline","true";"aria-label","Edit message";
    "autofocus","autofocus";
    "permitted-attachment-types",
      "application/vnd.campfire.mention application/vnd.actiontext.opengraph-embed";
    "data-action","lexxy:change->typing-notifications#start keydown->composer#submitByKeyboard:capture";
    "data-direct-upload-url",context.base_url ^ "/rails/active_storage/direct_uploads";
    "data-blob-url-template",context.base_url ^ "/rails/active_storage/blobs/redirect/:signed_id/:filename";
    "id","message_body";
    "input","message_body_trix_input_" ^ message_dom_id message "";
    "name","message[body]";"value",message.editable_body;
    "style","visibility: hidden";"data-wait-for-mount",""] [
      elt "lexxy-prompt" ["trigger","@";"name","mention";
        "src","/autocompletable/users?room_id=" ^ i64 message.room_id;
        "remote-filtering","true";"empty-results","No matches"] []] in
  let editable=match message.content with
    | Media_attachment _ | Attachment _ ->
        concat [message_presentation message;
          button_row [delete_button ~center:true ()]]
    | _ ->
        cls "div" "composer--edit composer--rich-text" [
          form ~attrs:["id",message_dom_id message "form";
            "data-controller","form";
            "data-action","lexxy:file-accept->form#preventAttachment keydown.esc->form#cancel keydown.ctrl+enter->form#submit:prevent keydown.meta+enter->form#submit:prevent";
            "accept-charset","UTF-8"] (permalink message) (concat [
            input ~name:"_method" ~kind:"hidden" ~value:"patch" ();
            cls "div" "full-width input input--actor min-width fill-white" [editor];
            elt "a" ["data-form-target","cancel";"hidden","hidden";
              "href",permalink message] [text "Close editor and discard changes"];
            button_row [
              elt "button" ["name","button";"type","submit";
                "class","btn btn--reversed"] [
                icon "check.svg" ["aria-hidden","true"];
                cls "span" "for-screen-reader" [text "Save changes"]];
              delete_button ()]])] in
  let frame = elt "turbo-frame" ["id",message_dom_id message "edit"] [
    elt "div" ["class","message__body position-relative";
      "data-controller","scroll-into-view"] [
      cls "div" "message__body-content message__body-content--editing gap"
        [editable];
      cls "div" "message__actions flex flex-wrap" [
        elt "a" ["class","message__action-btn message__edit-close-btn txt-small btn btn--borderless";
          "href",permalink message] [
          icon "remove.svg" ["class","colorize--black";"aria-hidden","true"];
          cls "span" "for-screen-reader" [text "Close editor and discard changes"]]];
      form ~attrs:["id",message_dom_id message "delete_form";
        "data-turbo-frame",message_dom_id message "edit";
        "accept-charset","UTF-8"] (permalink message)
        (input ~name:"_method" ~kind:"hidden" ~value:"delete" ())]] in
  page ~context ~head:lexxy_ready_head frame
let message_json ?(base_url="") ?(plain_text_body="") message =
  let full path = if String.starts_with ~prefix:"http" path then path
    else base_url ^ path in
  let html = match message.content with
    | Text (Trusted_html html) -> html | _ -> "" in
  let created_at = message.created_at_iso in
  let created_at = if String.length created_at > 23 then
    String.sub created_at 0 23 ^ "Z" else created_at in
  Rails_format.encode (`Assoc [
    "id",`Intlit (i64 message.id);
    "created_at",`String created_at;
    "body",`Assoc ["plain_text",`String plain_text_body;"html",`String html];
    "creator",`Assoc ["id",`Intlit (i64 message.creator.id);
      "name",`String message.creator.name;"role",`String message.creator.role;
      "avatar_url",`String (full message.creator.avatar_url)];
    "room",`Assoc ["id",`Intlit (i64 message.room_id)];
    "url",`String (base_url ^ relative_message message.room_id message.id)] )
let boost_json ~base_url ~room_id ~created_at (boost:boost) =
  let full path = if String.starts_with ~prefix:"http" path then path
    else base_url ^ path in
  Rails_format.encode (`Assoc [
    "id",`Intlit (i64 boost.id);
    "content",`String boost.content;
    "created_at",`String created_at;
    "booster",`Assoc [
      "id",`Intlit (i64 boost.booster.id);
      "name",`String boost.booster.name;
      "role",`String boost.booster.role;
      "avatar_url",`String (full boost.booster.avatar_url)];
    "message",`Assoc [
      "id",`Intlit (i64 boost.message_id);
      "url",`String (base_url ^ relative_message room_id boost.message_id)]])
let message_template context =
  let user = context.current_user in
  let user_id = Option.fold ~none:"0" ~some:(fun (user:user) -> i64 user.id) user in
  let user_name = Option.fold ~none:"" ~some:(fun (user:user) -> user.name) user in
  let user_title = Option.fold ~none:"" ~some:(fun (user:user) -> user.title) user in
  let open_tag name attributes =
    let rendered=render (elt name attributes []) in
    String.sub rendered 0 (String.index rendered '>' + 1) in
  let img attributes =
    let rendered=render (void "img" attributes) in
    let n=String.length rendered in
    if n>=2 && String.sub rendered (n-2) 2="/>" then
      String.sub rendered 0 (n-2) ^ " />" else rendered in
  let avatar = match user with None -> "" | Some user ->
    open_tag "a" ["title",user_title;"class","btn avatar";
      "data-turbo-frame","_top";"href",relative_user user.id] ^
    img ["aria-hidden","true";"src",user.avatar_url;
      "width","48";"height","48"] ^ "</a>" in
  let template=String.concat "" [
    open_tag "div" ["class","message message--me $messageClasses$";
      "id","message_$clientMessageId$";
      "data-format-message-target","message";"data-user-id",user_id;
      "data-message-timestamp","$messageTimestamp$";
      "data-messages-target","message"];
    " <div class=\"message__day-separator\"><time class=\"message__timestamp\" datetime=\"$messageDatetime$\" data-local-time-target=\"date\"></time></div>";
    " <figure class=\"avatar message__avatar\"> ";avatar;" </figure>";
    " <div class=\"message__body\"> <div class=\"message__body-content\">";
    " <div class=\"message__meta\"> <h3 class=\"message__heading\">";
    " <span class=\"message__author\"><strong>";
    render (text user_name);
    "</strong></span> <span class=\"message__permalink\"><time class=\"message__timestamp\" datetime=\"$messageDatetime$\" data-local-time-target=\"time\"></time></span> </h3>";
    " <div class=\"message__actions\"> <div class=\"position-relative\"> <span class=\"btn message__action-btn message__options-btn\"> ";
    img ["class","colorize--black";"aria-hidden","true";
      "src",asset context "menu-dots-horizontal.svg"];
    " <span class=\"for-screen-reader\">Message options</span> </span> </div class=\"position-relative\"> </div> </div> $body$ </div> </div> </div>"] in
  elt "script" ["type","text/template";"data-messages-target","template"]
    [raw (Trusted_html template)]
let room_noun (room:room) = if room.kind=Direct then "Ping" else "room"
let room_edit_path (room:room) =
  let id=i64 room.id in
  match room.kind with
  | Open -> Route_helpers.edit_rooms_open id
  | Closed -> Route_helpers.edit_rooms_closed id
  | Direct -> Route_helpers.edit_rooms_direct id
let notification_parts (context:context) =
  let platform = context.platform in
  let icon ?(size=20) ?(class_name="") ?alt name =
    void "img" (["src",asset context name;"width",string_of_int size;
      "height",string_of_int size] @
      (match alt with None -> ["aria-hidden","true"] | Some value -> ["alt",value]) @
      if class_name="" then [] else ["class",class_name]) in
  let li items = elt "li" [] items in
  let em items = elt "em" [] items in
  let detail ?(class_name="notifications-help") icon_name heading content =
    elt "details" ["class",class_name;
      "data-notifications-target","details"] [
      elt "summary" ["class","btn"] [
        icon icon_name;elt "strong" [] [text heading];
        icon ~size:10 ~class_name:"disclosure" "disclosure.svg"];
      content] in
  let mac_desktop = platform.operating_system="macOS" in
  let chrome_mac = (platform.chrome || platform.browser="Chrome") && mac_desktop in
  let safari_mac = (platform.safari || platform.browser="Safari") && not platform.ios in
  let apple_menu = elt "em" ["aria-label","the Apple menu"] [text ""] in
  let browser = if (platform.safari || platform.chrome) && platform.ios then
      concat []
    else if platform.firefox && platform.android then
      detail "external/web.svg" "Check your Firefox settings" (elt "ol" [] [
        li [text "Tap ";em [icon ~alt:"the View site information button"
          "lock.svg"];text " in the address bar."];
        li [text "Tap ";em [text "Notification"];
          text " to change to ";em [text "Allowed"];text "."]])
    else if platform.firefox && platform.desktop then
      detail "external/web.svg" ("Check your " ^ platform.browser ^ " settings")
        (concat [
          cls "h2" "txt-normal txt-medium margin-block-start"
            [text "Turn on notifications for this website."];
          elt "ol" [] [
            li [text "Click ";em [text platform.browser];text " in the top left."];
            li [text "Click ";em [text "Settings…"];text "."];
            li [text "Click ";em [text "Privacy & Security"];text " in the sidebar."];
            li [text "Scroll down to ";em [text "Permissions"];text "."];
            li [text "Click ";em [text "Settings"];
              text " next to ";em [text "Notifications"];text "."];
            li [text "Select ";em [text "Allow"];text " next to ";
              em [text (context.base_url ^ "/")];text "."]];
          cls "h2" "txt-normal txt-medium margin-block-start"
            [text ("Turn on notifications for " ^ platform.browser ^ ".")];
          elt "ol" [] [
            li [text "Click ";apple_menu;text " in the top left."];
            li [text "Click ";em [text "System Settings…"];text "."];
            li [text "Click ";em [text "Notifications"];text "."];
            li [text "Click ";em [text platform.browser];text "."];
            li [text "Click ";em [icon ~size:22 ~alt:"the switch"
              "external/switch.svg"];text " to ";
              em [text "Allow notifications"];text "."]]])
    else if platform.chrome && platform.windows && platform.desktop then
      detail "external/web.svg" ("Check your " ^ platform.browser ^ " settings")
        (concat [
          cls "h2" "txt-normal txt-medium margin-block-start"
            [text "Turn on notifications for this website."];
          elt "ol" [] [
            li [text "Click the ";em [icon ~alt:"View site information"
              "external/sliders.svg"];text " icon in the address bar."];
            li [text "Click ";em [text "Site Settings"];text "."];
            li [text "Ensure notifications are ";em [text "Allowed"];text "."]];
          cls "h2" "txt-normal txt-medium margin-block-start"
            [text ("Turn on notifications for " ^ platform.browser ^ ".")];
          elt "ol" [] [
            li [text "Click ";em [text "Start"];
              text ", then ";em [text "Settings"];text "."];
            li [text "Go to ";em [text "System > Notification"];text "."];
            li [text "Click ";em [icon ~size:22 ~alt:"the switch"
              "external/switch.svg"];text " ";em [text "ON"];
              text (" for " ^ platform.browser ^ ".")]]])
    else if platform.chrome && platform.android then
      detail "external/web.svg" ("Check your " ^ platform.browser ^ " settings")
        (elt "ol" [] [
          li [text "Tap the ";em [icon ~size:16 ~alt:"More options"
            "menu-dots-vertical.svg"];text " menu button."];
          li [text "Tap ";em [text "Settings"];text "."];
          li [text "Tap ";em [text "Notifications"];text "."];
          li [text "Tap ";em [icon ~size:22 ~alt:"the switch"
            "external/switch.svg"];text " to ";
            em [text ("Allow " ^ platform.browser ^ " notifications")];text "."];
          li [text "Tap ";em [icon ~size:22 ~alt:"the switch"
            "external/switch.svg"];text " next to ";em [text "Web apps"];text "."];
          li [text "Tap ";em [icon ~size:16 ~alt:"the notification bell"
            "notification-bell-alert.svg"];text " and select ";
            em [text "Allow"];text "."]])
    else if chrome_mac then
    detail "external/web.svg" "Check your Chrome settings" (concat [
      cls "h2" "txt-normal txt-medium margin-block-start"
        [text "Turn on notifications for this website."];
      elt "ol" [] [
        li [text "Click the ";em [icon ~alt:"View site information" "external/sliders.svg"];
          text " icon in the address bar."];
        li [text "Click ";em [text "Site Settings"];text "."];
        li [text "Ensure notifications are ";em [text "Allowed"];text "."]];
      cls "h2" "txt-normal txt-medium margin-block-start"
        [text "Turn on notifications for Chrome."];
      elt "ol" [] [
        li [text "Click ";elt "em" ["aria-label","the Apple menu"] [text ""];
          text " in the top left."];
        li [text "Click ";em [text "System Settings…"];text "."];
        li [text "Click ";em [text "Notifications"];text "."];
        li [text "Click ";em [text "Chrome"];text "."];
        li [text "Click ";em [icon ~size:22 ~alt:"the switch" "external/switch.svg"];
          text " to ";em [text "Allow notifications"];text "."]]])
    else if safari_mac then
      detail "external/web.svg" "Check your Safari settings" (elt "ol" [] [
        li [text "Click ";em [text "Safari"];text " in the top left."];
        li [text "Click ";em [text "Settings…"];text "."];
        li [text "Click the ";em [text "Websites"];text " tab."];
        li [text "Click ";em [text "Notifications"];text " in the sidebar."];
        li [text "Click ";em [text (context.base_url ^ "/")];text " in the list."];
        li [text "Select ";em [text "Allow"];text "."]])
    else detail "external/web.svg"
      ("Check your " ^ platform.browser ^ " settings")
      (elt "p" [] [text ("Ensure notifications are enabled for " ^
        context.base_url ^ "/ in your web browser settings.")]) in
  let system = if platform.firefox && platform.android then
    detail ~class_name:"notifications-help hide-in-browser"
      "external/gear.svg"
      ("Check your " ^ platform.operating_system ^ " settings")
      (elt "ol" [] [
        li [text "Tap the ";em [icon ~size:16 ~alt:"More options"
          "menu-dots-vertical.svg"];text " menu button."];
        li [text "Tap ";em [text "Settings"];text "."];
        li [text "Tap ";em [text "Notifications"];text "."];
        li [text "Tap ";em [icon ~size:22 ~alt:"the toggle button"
          "external/switch.svg"];text " to ";
          em [text ("Allow " ^ platform.browser ^ " notifications")];text "."]])
    else if (platform.chrome || platform.firefox) && platform.windows &&
        platform.desktop then
      detail ~class_name:"notifications-help hide-in-browser"
        "external/gear.svg"
        ("Check your " ^ platform.operating_system ^ " settings")
        (elt "ol" [] [
          li [text "Click ";em [text "Start"];text ", then ";
            em [text "Settings"];text "."];
          li [text "Go to ";em [text "System > Notification"];text "."];
          li [text "Click ";em [icon ~size:22 ~alt:"the toggle button"
            "external/switch.svg"];text " ";em [text "ON"];
            text " for Campfire."]])
    else if (platform.safari || platform.chrome) && platform.ios then
      detail ~class_name:"notifications-help hide-in-browser"
        "external/gear.svg"
        ("Check your " ^ platform.operating_system ^ " settings")
        (elt "ol" [] [
          li [text "Open the ";em [icon "external/gear.svg"];
            text " Settings app."];
          li [text "Scroll to and tap ";em [text "Campfire"];text "."];
          li [text "Tap ";em [text "Notifications"];text "."];
          li [text "Tap ";em [icon ~size:22
            ~alt:"the allow notifications switch button" "external/switch.svg"];
            text " to ";em [text "Allow Notifications"];text "."]])
    else if platform.chrome && platform.android then
      detail ~class_name:"notifications-help hide-in-browser"
        "external/gear.svg"
        ("Check your " ^ platform.operating_system ^ " settings")
        (elt "ol" [] [
          li [text "Open the ";em [icon "external/gear.svg"];
            text " Settings app."];
          li [text "Tap ";em [text "Notifications"];text "."];
          li [text "Tap ";em [text "App notifications"];text "."];
          li [text "Scroll to ";em [text "Campfire"];text "."];
          li [text "Tap ";em [icon ~size:22 ~alt:"the switch"
            "external/switch.svg"];text " to ";
            em [text "Allow Notifications"];text "."]])
    else if chrome_mac || safari_mac ||
        (platform.firefox && platform.desktop && mac_desktop) then
    detail ~class_name:"notifications-help hide-in-browser"
      "external/gear.svg"
      ("Check your " ^ platform.operating_system ^ " settings") (elt "ol" [] [
      li [text "Click ";apple_menu;
        text " in the top left."];
      li [text "Click ";em [text "System Settings…"];text "."];
      li [text "Click ";em [text "Notifications"];text "."];
      li [text "Click ";em [text "Campfire"];text "."];
      li [text "Click ";em [icon ~size:22 ~alt:"the allow notifications switch"
        "external/switch.svg"];
        text " to ";em [text "Allow notifications"];text "."]])
    else detail ~class_name:"notifications-help hide-in-browser"
      "external/gear.svg"
      ("Check your " ^ platform.operating_system ^ " settings")
      (elt "p" [] [text ("Ensure notifications are allowed for " ^
        platform.browser ^ " in your system settings.")]) in
  let install = if safari_mac ||
      (platform.firefox && platform.android) ||
      ((platform.safari || platform.chrome) && platform.ios) then
    [elt "details" ["class","notifications-help pwa__instructions hide-in-pwa";
      "data-controller","pwa-install";
      "data-pwa-install-prompting-class","pwa--can-install";
      "data-notifications-target","details"] [
      elt "summary" ["class","btn"] [
        icon "external/install.svg";
        elt "strong" [] [text "Install Campfire as a web app."];
        icon ~size:10 ~class_name:"disclosure" "disclosure.svg"];
      (if platform.firefox && platform.android then
        elt "ol" [] [
          li [text "Tap the ";em [icon ~size:16 ~alt:"More options"
            "menu-dots-vertical.svg"];text " menu button."];
          li [text "Tap ";em [text "Install"];text " in the menu."]]
      else if platform.ios then concat [
        elt "p" [] [text ("To receive push notifications in " ^
          platform.browser ^ " for " ^ platform.operating_system ^
          ", you must install Campfire as a web app.")];
        elt "ol" [] [
          li [text "Tap ";em [icon ~alt:"the share button"
            "external/share.svg"]];
          li [text "Tap ";em [text "Add to Home Screen"];text "."]]]
      else elt "ol" [] [
        li [text "Click ";em [text "File"];text " in the top left."];
        li [text "Click ";em [text "Add to Dock…"];text "."]]);
      cls "div" "margin-block-start txt-align-center pwa__installer" [
        void "hr" ["class","separator margin-block"];
        elt "button" ["class","btn btn--reversed center";
          "data-action","pwa-install#promptInstall"] [
            void "img" ["src",asset context "external/install.svg";
              "aria-hidden","true"];
            text "Install now"]]]]
    else [] in
  browser,system,install
let pwa_browser_settings context =
  let browser,_,_=notification_parts context in browser
let pwa_system_settings context =
  let _,system,_=notification_parts context in system
let pwa_install_instructions context =
  let _,_,install=notification_parts context in concat install

type profile_membership = {
  room_id:int64; room_param_key:string; room_display_name:string;
  involvement:string; direct:bool
}

let profile_membership_item ~context (membership:profile_membership) =
  let suffix=membership.room_param_key ^ "_" ^ i64 membership.room_id in
  let next=match membership.involvement with
    | "mentions" -> "everything"
    | "everything" -> "nothing"
    | "nothing" when membership.direct -> "everything"
    | "nothing" -> "invisible"
    | _ -> "mentions" in
  let label=match membership.involvement with
    | "mentions" -> "Notifying about @ mentions"
    | "everything" -> "Notifying about all messages"
    | "invisible" -> "Notifications are off and room invisible in sidebar"
    | _ -> "Notifications are off" in
  let action=Route_helpers.room_involvement (i64 membership.room_id) ^
    "?involvement=" ^ next in
  elt "li" ["class","flex align-center gap margin-none min-width membership-item"] [
    elt "a" ["class","overflow-ellipsis fill-shade txt-primary txt-undecorated";
      "href",relative_room membership.room_id] [
      elt "strong" [] [text membership.room_display_name]];
    void "hr" ["class","separator";"aria-hidden","true"];
    cls "span" "txt-small" [
      id "turbo-frame" ("involvement_" ^ suffix) [
        elt "form" ["class","button_to";"method","post";"action",action] [
          input ~name:"_method" ~kind:"hidden" ~value:"put" ();
          elt "button" ["role","checkbox";"aria-checked","true";
            "aria-labelledby","involvement_label_" ^ suffix;
            "tabindex","0";"class","btn " ^ membership.involvement;
            "type","submit"] [
            void "img" ["aria-hidden","true";
              "src",asset context ("notification-bell-" ^ membership.involvement ^ ".svg");
              "width","20";"height","20"];
            elt "span" ["class","for-screen-reader";
              "id","involvement_label_" ^ suffix] [text label]]]]]]

let profile_show_page ~context ?(back_url="/") ~(user:user)
    ~email_address ~bio ~avatar_attached ~transfer_id
    ~shared_memberships ~direct_memberships () =
  let icon ?(size=None) ?(attrs=[]) name =
    void "img" (attrs @ ["src",asset context (name ^ ".svg")] @
      match size with None -> [] | Some value ->
        ["width",string_of_int value;"height",string_of_int value]) in
  let nav=concat [
    cls "div" "flex-item-justify-start" [
      elt "a" ["class","btn";"href",back_url] [
        icon ~size:(Some 20) ~attrs:["aria-hidden","true"] "arrow-left";
        cls "span" "for-screen-reader" [text "Go Back"]]];
    cls "div" "flex-item-justify-end" [
      elt "form" ["data-controller","sessions";"action","/session";
        "accept-charset","UTF-8";"method","post"] [
        input ~name:"_method" ~kind:"hidden" ~value:"delete" ();
        void "input" ["type","hidden";"name","push_subscription_endpoint";
          "id","push_subscription_endpoint";
          "data-sessions-target","pushSubscriptionEndpoint"];
        elt "button" ["class","btn";
          "data-action","sessions#logout:prevent"] [
          icon ~attrs:["aria-hidden","true"] "logout";
          cls "span" "for-screen-reader" [text "Log out"]]]]] in
  let action="/users/me/profile" in
  let profile_form ?(attrs=[]) ?(multipart=false) content =
    elt "form" (attrs @ ["data-controller","form"] @
      (if multipart then ["enctype","multipart/form-data"] else []) @
      ["action",action;"accept-charset","UTF-8";"method","post"]) [
      input ~name:"_method" ~kind:"hidden" ~value:"patch" ();
      content] in
  let avatar_field large =
    elt "label" ["class",if large then "btn avatar input--file txt-xx-large"
      else "btn input--file"] [
      (if large then
        void "img" ["aria-hidden","true";
          "data-upload-preview-target","image";
          "src",user.avatar_url;"width","300";"height","300"]
       else icon ~size:(Some 20) ~attrs:["aria-hidden","true"] "camera");
      void "input" ["id","file";"class","input";
        "accept","image/*";"data-upload-preview-target","input";
        "data-action","upload-preview#previewImage change->form#submit";
        "type","file";"name","user[avatar]"];
      cls "span" "for-screen-reader" [text (if large then "Avatar" else "Upload avatar")]] in
  let avatar=elt "div" ["class","align-center center avatar__form gap";
    "data-controller","upload-preview"] [
    profile_form ~attrs:["class","txt-medium"] ~multipart:true
      (avatar_field false);
    profile_form ~multipart:true (avatar_field true);
    (if avatar_attached then
      elt "form" ["class","button_to";"method","post";
        "action",relative_user user.id ^ "/avatar"] [
        input ~name:"_method" ~kind:"hidden" ~value:"delete" ();
        elt "button" ["class","btn btn--negative txt-small avatar__delete-btn";
          "type","submit"] [
          icon ~size:(Some 20) ~attrs:["aria-hidden","true"] "minus";
          cls "span" "for-screen-reader" [text "Delete avatar"]]]
     else concat [])] in
  let field ~key ~translation ~kind ~icon_name ~class_name
      ~attributes ?value () =
    cls "div" "flex align-center gap" [
      translation_button context translation;
      cls "label" "flex align-center gap flex-item-grow input input--actor" [
        void "input" (["class",class_name] @ attributes @
          ["type",kind] @ (match value with None -> [] | Some value ->
            ["value",value]) @ ["name","user[" ^ key ^ "]";
            "id","user_" ^ key]);
        icon ~size:(Some 24) ~attrs:["aria-hidden","true";
          "class","colorize--black"] icon_name]] in
  let fields=profile_form (cls "div" "flex flex-column gap" [
    field ~key:"name" ~translation:"user_name" ~kind:"text"
      ~icon_name:"person"
      ~class_name:"input txt-large "
      ~attributes:["autocomplete","name";"placeholder","Enter your name";
        "autofocus","autofocus";"required","required";
        "data-1p-ignore","true"] ~value:user.name ();
    field ~key:"email_address" ~translation:"email_address" ~kind:"email"
      ~icon_name:"email"
      ~class_name:"input txt-large"
      ~attributes:["autocomplete","username";
        "placeholder","Enter your email address"] ~value:email_address ();
    field ~key:"password" ~translation:"update_password" ~kind:"password"
      ~icon_name:"password"
      ~class_name:"input txt-large"
      ~attributes:["autocomplete","new-password";
        "placeholder","Change password";"maxlength","72";"size","72"] ();
    cls "div" "flex align-start gap" [
      translation_button context "bio";
      cls "label" "flex align--center gap flex-item--grow input input--actor" [
        elt "textarea" ["class","input txt-large";
          "placeholder","A few words about yourself…";"maxlength","200";
          "rows","3";"name","user[bio]";"id","user_bio"] [
          text (Option.value bio ~default:"")];
        icon ~size:(Some 24) ~attrs:["aria-hidden","true";
          "class","colorize--black"] "bio"]];
    elt "button" ["class","btn btn--reversed center txt-large";
      "type","submit"] [
      icon ~size:(Some 20) ~attrs:["aria-hidden","true"] "check";
      cls "span" "for-screen-reader" [text "Save changes"]]]) in
  let memberships=cls "div" "margin-block pad-inline pad-block fill-shade border-radius" [
    cls "menu" "flex flex-column gap margin-none pad" [
      concat (List.map (profile_membership_item ~context) shared_memberships);
      (if shared_memberships<>[] && direct_memberships<>[] then
        void "hr" ["class","separator full-width";
          "style","--border-style: solid"] else concat []);
      concat (List.map (profile_membership_item ~context) direct_memberships)]] in
  let content=elt "section" ["class","panel flex flex-column gap";
    "style","view-transition-name: avatar-" ^ i64 user.id] [
    pwa_install_instructions context;avatar;fields;memberships;
    profile_transfer_fragment ~context ~user ~transfer_id] in
  page ~title:user.name ~context ~nav content
let notification_help context =
  let browser,system,install=notification_parts context in
  cls "div" "txt-align-start margin-block-start" ([browser;system] @ install)
let room_bell context (room:room) =
  let icon ?(hidden=false) ?(size=20) name =
    void "img" (["aria-hidden","true";"src",asset context name;
      "width",string_of_int size;"height",string_of_int size] @
      if hidden then ["hidden","hidden"] else []) in
  let frame = elt "turbo-frame" ["data-controller","turbo-frame";
    "data-action","notifications:ready@window->turbo-frame#load";
    "data-turbo-frame-url-param",Route_helpers.room_involvement (i64 room.id);
    "id",room_dom_id room "involvement"] [
    elt "button" ["class","btn";
      "data-action","click->notifications#attemptToSubscribe";
      "data-notifications-target","bell"] [
      icon "notification-bell-loading.svg";
      icon ~hidden:true "notification-bell-alert.svg";
      cls "span" "for-screen-reader"
        [text ("Notification settings for this " ^ room_noun room)]]] in
  let notice = elt "dialog" ["data-notifications-target","notAllowedNotice";
    "class","dialog pad center center-block border-radius border shadow";
    "style","--inline-space: var(--block-space)"] [
    cls "div" "flex flex-column txt-align-center" [
      cls "span" "btn btn--faux center txt-x-large" [
        icon ~size:48 "notification-bell-alert.svg";
        cls "span" "for-screen-reader" [text "Notifications alert"]];
      elt "section" [] [
        cls "h1" "txt-large margin-none" [text "Notifications aren’t allowed"];
        notification_help context];
      elt "form" ["method","dialog";"class","flex align-center gap center"] [
        elt "button" ["class","btn dialog__close";"autofocus","true"] [
          cls "span" "for-screen-reader" [text "Close"];
          icon "remove.svg"]]]] in
  elt "span" [] [elt "span" ["class","button_to_change_notifying";
    "data-controller","notifications";
    "data-notifications-subscriptions-url-value",Route_helpers.user_push_subscriptions ();
    "data-notifications-attention-class","btn--pulsing"] [frame;notice]]
let room_involvement_frame ~context ~(room:room) ~involvement =
  let order=if room.kind=Direct then ["everything";"nothing"]
    else ["mentions";"everything";"nothing";"invisible"] in
  let rec next = function
    | [] -> List.hd order
    | [_] -> List.hd order
    | first::(second::_ as rest) ->
        if first=involvement then second else next rest in
  let label=match involvement with
    | "mentions" -> "Notifying about @ mentions"
    | "everything" -> "Notifying about all messages"
    | "nothing" -> "Notifications are off"
    | "invisible" -> "Notifications are off and room invisible in sidebar"
    | _ -> "" in
  let label_id=room_dom_id room "involvement_label" in
  let path=Route_helpers.room_involvement (i64 room.id) in
  elt "turbo-frame" ["data-controller","turbo-frame";
    "data-action","notifications:ready@window->turbo-frame#load";
    "data-turbo-frame-url-param",path;
    "id",room_dom_id room "involvement"] [
    form ~attrs:["class","button_to"]
      (path ^ "?involvement=" ^ next order) (concat [
      input ~name:"_method" ~kind:"hidden" ~value:"put" ();
      elt "button" ["role","checkbox";"aria-checked","true";
        "aria-labelledby",label_id;"tabindex","0";
        "class","btn " ^ involvement;"type","submit"] [
        void "img" ["aria-hidden","true";
          "src",asset context ("notification-bell-" ^ involvement ^ ".svg");
          "width","20";"height","20"];
        elt "span" ["class","for-screen-reader";"id",label_id]
          [text label]]])]
let room_nav context (room:room) =
  let settings_icon=void "img" ["aria-hidden","true";
    "src",asset context "menu-dots-horizontal.svg";"width","20";"height","20"] in
  let name = elt "span" ["class","btn btn--reversed btn--faux room--current"] [
    cls "h1" "room__contents txt-medium overflow-ellipsis"
      ((if room.kind=Direct then
          [cls "span" "for-screen-reader" [text "Ping with"]] else []) @
       [text room.name])] in
  concat [name;
    elt "a" ["class","btn";
      "style","view-transition-name: edit-room-" ^ i64 room.id;
      "data-room-id",i64 room.id;"href",room_edit_path room] [
      settings_icon;
      cls "span" "for-screen-reader"
        [text ("Settings for this " ^ room_noun room)]];
    room_bell context room]
let room_invitation context join_code =
  elt "div" ["id","system_welcome";
    "class","message message--formatted txt-align-center center"] [
    cls "div" "message__body center" [
      cls "div" "message__body-content position-relative" [
        cls "figure" "account-logo avatar center margin-block-end txt-large" [
          image ~width:300 ~height:300 ~alt:"Account logo" context.logo_url];
        cls "div" "flex align-center gap" [
          cls "div" "system-welcome--translation" [
            translation_button context "invite_message"];
          elt "p" [] [
            elt "strong" [] [text "Welcome to Campfire"];
            void "br" [];
            text "To invite people to chat, share the join link below."]];
        invite_fragment context join_code]]]
let room_show ~context ~(room:room) ~messages ~messages_stream_name
    ?invitation_join_code () =
  let head = concat [
    lexxy_ready_head;
    void "meta" ["name","turbo-cache-control";"content","no-preview"];
    void "meta" ["name","current-room-id";"content",i64 room.id]] in
  let nav = room_nav context room in
  let invitation = match invitation_join_code with None -> concat [] |
    Some code -> room_invitation context code in
  let content = elt "div" ["id","message-area";"class","message-area";
    "contents","true";"data-controller","messages presence drop-target";
    "data-action","turbo:before-stream-render@document->messages#beforeStreamRender keydown.up@document->messages#editMyLastMessage dragenter->drop-target#dragenter dragover->drop-target#dragover drop->drop-target#drop visibilitychange@document->presence#visibilityChanged";
    "data-messages-first-of-day-class","message--first-of-day";
    "data-messages-formatted-class","message--formatted";
    "data-messages-me-class","message--me";
    "data-messages-mentioned-class","message--mentioned";
    "data-messages-threaded-class","message--threaded";
    "data-messages-page-url-value",context.base_url ^ relative_room room.id ^ "/messages"] [
      message_template context;
      elt "div" ["id",room_dom_id room "messages";"class","messages";
        "data-controller","maintain-scroll refresh-room";
        "data-action","turbo:before-stream-render@document->maintain-scroll#beforeStreamRender visibilitychange@document->refresh-room#visibilityChanged online@window->refresh-room#online";
        "data-messages-target","messages";
        "data-refresh-room-loaded-at-value",i64 room.updated_at_ms;
        "data-refresh-room-url-value",context.base_url ^ relative_room room.id ^ "/refresh"]
        (invitation :: List.map message_item messages);
      elt "turbo-cable-stream-source" ["channel","RoomMessagesChannel";
        "signed-stream-name",messages_stream_name] [];
      elt "button" ["class","message-area__return-to-latest btn";
        "data-action","messages#returnToLatest";"data-messages-target","latest";
        "hidden","hidden"] [
          void "img" ["aria-hidden","true";"src",asset context "arrow-down.svg";
            "width","20";"height","20"];
          cls "span" "for-screen-reader" [text "Jump to newest message"]]] in
  let composer_icon ?(size=20) ?(class_name="") name =
    void "img" (["aria-hidden","true";"src",asset context name;
      "width",string_of_int size;"height",string_of_int size] @
      if class_name="" then [] else ["class",class_name]) in
  let footer = elt "div" ["class","composer flex align-end gap position-relative";
    "data-controller","typing-notifications";
    "data-typing-notifications-active-class","typing-indicator--active"] [
    elt "a" ["class","btn flex-item-no-shrink margin-block-end composer__context-btn";
      "style","view-transition-name: input-switcher";
      "href",Route_helpers.searches ()] [
        composer_icon "search.svg";
        cls "span" "for-screen-reader" [text "Search"]];
    elt "turbo-frame" ["id","composer-frame"] [
      form ~attrs:["id","composer";
        "accept-charset","UTF-8";
        "class","margin-block flex-item-grow contain";
        "data-controller","composer drop-target";
        "data-composer-messages-outlet","#message-area";
        "data-composer-room-id-value",i64 room.id;
        "data-composer-toolbar-class","composer--rich-text";
        "data-action","dragenter->drop-target#dragenter dragover->drop-target#dragover drop->drop-target#drop drop-target:drop@window->composer#dropFiles lexxy:file-accept->composer#preventAttachment refresh-room:online@window->composer#online typing-notifications#stop paste->composer#pasteFiles turbo:submit-end->composer#submitEnd refresh-room:offline@window->composer#offline"]
        (relative_room room.id ^ "/messages") (concat [
          elt "fieldset" ["data-composer-target","fields";"contents",""] [
            cls "div" "flex flex-column" [
              elt "div" ["class","composer__filelist flex flex--align-center gap flex-wrap";
                "data-composer-target","fileList"] [];
              elt "div" ["class","flex composer__input input input--actor fill-white min-width";
                "style","--input-border-radius: 1.3rem"] [
                cls "div" "flex align-end gap full-width" [
                  void "img" ["aria-hidden","true";
                    "class","composer__input-hint colorize--black";
                    "style","view-transition-name: input-btn;";
                    "src",asset context "messages-outlined.svg";"width","22";"height","22"];
                  cls "div" "flex flex-column flex-item-grow min-width gap" [
                    elt "lexxy-editor" ["rows","1";"class","input lexxy-content";
                      "style","order: -1";"aria-multiline","true";
                      "aria-label","Write a message";
                      "permitted-attachment-types","application/vnd.campfire.mention application/vnd.actiontext.opengraph-embed";
                      "data-controller","unfurl";
                      "data-action","lexxy:change->typing-notifications#start keydown->composer#submitByKeyboard:capture lexxy:change->composer#saveDraft lexxy:insert-link->unfurl#unfurl";
                      "data-composer-target","text";
                      "data-direct-upload-url",context.base_url ^ "/rails/active_storage/direct_uploads";
                      "data-blob-url-template",context.base_url ^ "/rails/active_storage/blobs/redirect/:signed_id/:filename";
                      "id","message_body";"input","message_body_trix_input_message";
                      "name","message[body]"] [
                      elt "lexxy-prompt" ["trigger","@";"name","mention";
                        "src",Route_helpers.autocompletable_users () ^ "?room_id=" ^ i64 room.id;
                        "remote-filtering","true";"empty-results","No matches"] []]];
                  elt "label" ["class","btn btn--borderless txt-small flex-item-no-shrink composer__attachment-btn input--file"] [
                    composer_icon ~size:22 ~class_name:"colorize--black" "attachment.svg";
                    void "input" ["type","file";"data-action","composer#filePicked";"multiple",""];
                    cls "span" "for-screen-reader" [text "Attach a file"]];
                  elt "button" ["class","btn btn--borderless txt-small flex-item-no-shrink composer__rich-text-btn";
                    "type","button";"data-action","composer#toggleToolbar"] [
                    composer_icon ~class_name:"colorize--black" "text-options.svg";
                    cls "span" "for-screen-reader" [text "Rich text"]];
                  elt "button" ["name","send";"type","submit";
                    "data-action","composer#submit";
                    "class","btn btn--reversed flex-item-no-shrink txt-small"] [
                    composer_icon "arrow-up.svg";
                    cls "span" "for-screen-reader" [text "Send Message"]]]]]];
          elt "div" ["class","typing-indicator gap txt-small align-center flex-inline";
            "data-typing-notifications-target","indicator"] [
            elt "div" ["class","typing-indicator__author spinner";
              "data-typing-notifications-target","author"] []];
          input ~name:"message[client_message_id]" ~kind:"hidden"
            ~attrs:["data-composer-target","clientid";
              "id","message_client_message_id"] ()])]] in
  let sidebar = elt "turbo-frame" ["id","user_sidebar";
    "src",Route_helpers.user_sidebar ();
    "target","_top";"data-turbo-permanent","true";
    "data-controller","rooms-list read-rooms turbo-frame";
    "data-rooms-list-unread-class","unread";
    "data-action","presence:present@window->rooms-list#read read-rooms:read->rooms-list#read turbo:frame-load->rooms-list#loaded refresh-room:visible@window->turbo-frame#reload"] [] in
  page ~title:room.name ~body_class:"sidebar" ~head ~nav ~sidebar ~footer
    ~context content
let search_index_with ~context ~query ?q ?(recent_searches=[])
    ?(return_to_room_id=0L) ~results () =
  let q=match q with Some _ -> q | None ->
    if query="" then None else Some query in
  let icon ?(attributes=[]) name =
    void "img" (attributes @ ["src",asset context name]) in
  let recents=concat (List.map (fun search ->
      elt "a" ["class","align-center gap room btn txt-nowrap";
        "href","/searches?q=" ^ Ruby_compat.cgi_escape search] [
        cls "span" "overflow-ellipsis" [text ("“" ^ search ^ "”")]])
      recent_searches @
    if recent_searches=[] then [] else [
      form ~attrs:["class","button_to"]
        (context.base_url ^ "/searches/clear") (concat [
        input ~name:"_method" ~kind:"hidden" ~value:"delete" ();
        elt "button" ["class","btn searches__btn";
          "data-turbo-confirm","Are you sure you want to clear your recent searches?";
          "type","submit"] [
          icon "broom.svg" ~attributes:["aria-hidden","true"];
          cls "span" "for-screen-reader" [text "Clear recent searches"]]])]) in
  let nav=concat [
    (if query="" then concat [] else
      cls "div" "searches__query flex align-center gap pad-block-start-half" [
        cls "div" "btn btn--reversed btn--faux align-center gap txt-nowrap" [
          cls "span" "overflow-ellipsis" [text ("“" ^ query ^ "”")];
          cls "span" "flex-item-no-shrink" [
            text (string_of_int (List.length results))]]]);
    cls "div" "searches__recents align-center gap pad-block-half overflow-y overflow-hide-scrollbar"
      [recents]] in
  let sidebar=cls "div" "rooms position-relative flex flex-column gap overflow-y overflow-hide-scrollbar"
    [recents] in
  let footer=cls "div" "composer flex align-end gap" [
    elt "a" ["class","btn flex-item-no-shrink margin-block-end";
      "style","view-transition-name: input-switcher; --btn-border-radius: 0.5em";
      "href",relative_room return_to_room_id] [
      icon "arrow-left.svg" ~attributes:["aria-hidden","true"];
      cls "span" "for-screen-reader" [text "Exit search "]];
    form ~attrs:["class","margin-block flex-item-grow contain flex align-center gap";
      "data-controller","form";"data-action","keydown.esc->form#cancel";
      "accept-charset","UTF-8"] "/searches"
      (cls "div" "composer__input flex align-center flex-item-grow gap full-width input input--actor min-width" [
        icon "search.svg" ~attributes:["aria-hidden","true";
          "class","composer__input-hint colorize--black";
          "style","view-transition-name: input-btn;";
          "width","20";"height","20"];
        void "input" ((match q with None -> [] | Some value -> ["value",value]) @
          ["class","searches__input input flex-item-grow";
            "role","searchbox";"aria-label","search";
            "autofocus","autofocus";"required","required";
            "type","text";"name","q";"id","q"]);
        elt "a" ["data-form-target","cancel";"role","button";
          "class","searches__reset";"href","/searches"] [
          icon "remove.svg" ~attributes:["aria-hidden","true";
            "class","colorize--black";"width","14";"height","14"];
          cls "span" "for-screen-reader" [text "Clear search field"]];
        elt "button" ["name","button";"type","submit";
          "class","btn btn--reversed flex-item-no-shrink txt-small";
          "style","--btn-border-radius: 0.5em"] [
          icon "arrow-up.svg" ~attributes:["aria-hidden","true"];
          cls "span" "for-screen-reader" [text "Search"]]])] in
  let content=elt "div" ["id","message-area";"class","message-area"] [
    cls "div" "message-area--empty min-width center" [
      cls "figure" "center pad" [
        icon "search.svg" ~attributes:["aria-hidden","true";
          "class","colorize--black translucent"]]];
    elt "div" ["id","search-results";"class","messages searches__results";
      "data-controller","search-results";
      "data-search-results-target","messages";
      "data-search-results-me-class","message--me";
      "data-search-results-threaded-class","message--threaded";
      "data-search-results-mentioned-class","message--mentioned";
      "data-search-results-formatted-class","message--formatted"] [
      message_index results]] in
  page ~title:"Search" ~body_class:"sidebar searches" ~context
    ~nav ~sidebar ~footer content
let search_index ~context ~query ~results =
  search_index_with ~context ~query ~results ()
let turbo_stream ~action ~target content =
  render (elt "turbo-stream" ["action",action;"target",target]
    [elt "template" [] [content]])
let message_create_stream ~room message =
  turbo_stream ~action:"append" ~target:(room_dom_id room "messages")
    (message_item message)
let message_destroy_stream message =
  render (elt "turbo-stream" ["action","remove";
    "target",message_dom_id message ""] [])
let room_refresh_stream ~room ~created ~updated =
  let append = match created with [] -> "" | _ ->
    turbo_stream ~action:"append"
      ~target:(room_dom_id room "messages") (message_index created) in
  let replace message = turbo_stream ~action:"replace"
    ~target:(message_dom_id message "") (message_item message) in
  append ^ "\n" ^ String.concat ""
    (List.map (fun message -> "  " ^ replace message ^ "\n") updated)
let account_users_stream ~users ~next_page =
  let rows = concat (List.map user_row users) in
  turbo_stream ~action:"append" ~target:"account_users" rows ^
  (match next_page with None -> "" | Some page ->
    turbo_stream ~action:"replace" ~target:"next_page" (a
      ("/account/edit?page=" ^ Uri.pct_encode page) [text "More users"]))
