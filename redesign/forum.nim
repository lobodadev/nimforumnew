import strformat, times, options, json
from dom import window, Location

include karax/prelude


import threadlist, postlist, karaxutils

type
  State = ref object
    url: Location

proc newState(): State =
  State(
    url: window.location
  )

var state = newState()
proc onPopState(event: dom.Event) =
  # This event is usually only called when the user moves back in their
  # history. I fire it in karaxutils.anchorCB as well to ensure the URL is
  # always updated. This should be moved into Karax in the future.
  kout(kstring"New URL: ", window.location.href)
  state.url = window.location
  redraw()

proc genHeader(): VNode =
  result = buildHtml(header(id="main-navbar")):
    tdiv(class="navbar container grid-xl"):
      section(class="navbar-section"):
        a(href=makeUri("/")):
          img(src="images/crown.png", id="img-logo") # TODO: Customisation.
      section(class="navbar-section"):
        tdiv(class="input-group input-inline"):
          input(class="form-input input-sm", `type`="text", placeholder="search")
        button(class="btn btn-primary btn-sm"):
          italic(class="fas fa-user-plus")
          text " Sign up"
        button(class="btn btn-primary btn-sm"):
          italic(class="fas fa-sign-in-alt")
          text " Log in"

proc render(): VNode =
  result = buildHtml(tdiv()):
    genHeader()
    if "/t/" in state.url.pathname:
      renderPostList(3806, false)
    else:
      renderThreadList()

window.onPopState = onPopState
setRenderer render