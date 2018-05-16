
import options, json, times, httpcore, strformat, sugar, math, strutils

import threadlist, category, post, user
type

  PostList* = ref object
    thread*: Thread
    history*: seq[Thread] ## If the thread was edited this will contain the
                          ## older versions of the thread (title/category
                          ## changes).
    posts*: seq[Post]

when defined(js):
  from dom import nil

  include karax/prelude
  import karax / [vstyles, kajax, kdom]

  import karaxutils, error, replybox

  type
    State = ref object
      list: Option[PostList]
      loading: bool
      status: HttpCode
      replyingTo: Option[Post]
      replyBox: ReplyBox

  proc onReplyPosted(id: int)
  proc newState(): State =
    State(
      list: none[PostList](),
      loading: false,
      status: Http200,
      replyingTo: none[Post](),
      replyBox: newReplyBox(onReplyPosted)
    )

  var
    state = newState()

  proc onPostList(httpStatus: int, response: kstring, postId: Option[int]) =
    state.loading = false
    state.status = httpStatus.HttpCode
    if state.status != Http200: return

    let parsed = parseJson($response)
    let list = to(parsed, PostList)

    state.list = some(list)

    # The anchor should be jumped to once all the posts have been loaded.
    if postId.isSome():
      discard setTimeout(
        () => (
          # Would have used scrollIntoView but then the `:target` selector
          # isn't activated.
          window.location.hash = "";
          window.location.hash = "#" & $postId.get()
        ),
        100
      )

  proc onMorePosts(httpStatus: int, response: kstring, start: int) =
    state.loading = false
    state.status = httpStatus.HttpCode
    if state.status != Http200: return

    let parsed = parseJson($response)
    var list = to(parsed, seq[Post])

    var idsLoaded: seq[int] = @[]
    for i in 0..<list.len:
      state.list.get().posts.insert(list[i], i+start)
      idsLoaded.add(list[i].id)

    # Save a list of the IDs which have not yet been loaded into the top-most
    # post.
    let postIndex = start+list.len
    # The following check is necessary because we reuse this proc to load
    # a newly created post.
    if postIndex < state.list.get().posts.len:
      let post = state.list.get().posts[postIndex]
      var newPostIds: seq[int] = @[]
      for id in post.moreBefore:
        if id notin idsLoaded:
          newPostIds.add(id)
      post.moreBefore = newPostIds

  proc loadMore(start: int, ids: seq[int]) =
    if state.loading: return

    state.loading = true
    let uri = makeUri(
      "specific_posts.json",
      [("ids", $(%ids))]
    )
    ajaxGet(
      uri,
      @[],
      (s: int, r: kstring) => onMorePosts(s, r, start)
    )

  proc onReplyPosted(id: int) =
    ## Executed when a reply has been successfully posted.
    loadMore(state.list.get().posts.len, @[id])

  proc onReplyClick(e: Event, n: VNode, p: Option[Post]) =
    state.replyingTo = p
    state.replyBox.show()

  proc onLoadMore(ev: Event, n: VNode, start: int, post: Post) =
    loadMore(start, post.moreBefore) # TODO: Don't load all!

  proc genLoadMore(post: Post, start: int): VNode =
    result = buildHtml():
      tdiv(class="information load-more-posts",
           onClick=(e: Event, n: VNode) => onLoadMore(e, n, start, post)):
        tdiv(class="information-icon"):
          italic(class="fas fa-comment-dots")
        tdiv(class="information-main"):
          if state.loading:
            tdiv(class="loading loading-lg")
          else:
            tdiv(class="information-title"):
              text "Load more posts "
              span(class="more-post-count"):
                text "(" & $post.moreBefore.len & ")"

  proc genPost(post: Post, thread: Thread, isLoggedIn: bool): VNode =
    let postCopy = post # TODO: Another workaround here, closure capture :(
    result = buildHtml():
      tdiv(class="post", id = $post.id):
        tdiv(class="post-icon"):
          render(post.author, "post-avatar")
        tdiv(class="post-main"):
          tdiv(class="post-title"):
            tdiv(class="post-username"):
              text post.author.name
            tdiv(class="post-time"):
              let title = post.info.creation.fromUnix().local.
                          format("MMM d, yyyy HH:mm")
              a(href=renderPostUrl(post, thread), title=title):
                text renderActivity(post.info.creation)
          tdiv(class="post-content"):
            verbatim(post.info.content)
          tdiv(class="post-buttons"):
            tdiv(class="like-button"):
              button(class="btn"):
                span(class="like-count"):
                  if post.likes.len > 0:
                    text $post.likes.len
                  italic(class="far fa-heart")
            if isLoggedIn:
              tdiv(class="flag-button"):
                button(class="btn"):
                  italic(class="far fa-flag")
              tdiv(class="reply-button"):
                button(class="btn", onClick=(e: Event, n: VNode) =>
                       onReplyClick(e, n, some(postCopy))):
                  italic(class="fas fa-reply")
                  text " Reply"

  proc genTimePassed(prevPost: Post, post: Option[Post], last: bool): VNode =
    var latestTime =
      if post.isSome: post.get().info.creation.fromUnix()
      else: getTime()

    # TODO: Use `between` once it's merged into stdlib.
    let
      tmpl =
        if last: [
            "A long time since last reply",
            "$1 year since last reply",
            "$1 years since last reply",
            "$1 month since last reply",
            "$1 months since last reply",
          ]
        else: [
          "Some time later",
          "$1 year later", "$1 years later",
          "$1 month later", "$1 months later"
        ]
    var diffStr = tmpl[0]
    let diff = latestTime - prevPost.info.creation.fromUnix()
    if diff.weeks > 48:
      let years = diff.weeks div 48
      diffStr =
        (if years == 1: tmpl[1] else: tmpl[2]) % $years
    elif diff.weeks > 4:
      let months = diff.weeks div 4
      diffStr =
        (if months == 1: tmpl[3] else: tmpl[4]) % $months
    else:
      return buildHtml(tdiv())

    # PROTIP: Good thread ID to test this with is: 1267.
    result = buildHtml():
      tdiv(class="information time-passed"):
        tdiv(class="information-icon"):
          italic(class="fas fa-clock")
        tdiv(class="information-main"):
          tdiv(class="information-title"):
            text diffStr

  proc renderPostList*(threadId: int, postId: Option[int],
                       isLoggedIn: bool): VNode =
    if state.status != Http200:
      return renderError("Couldn't retrieve posts.")

    if state.list.isNone or state.list.get().thread.id != threadId:
      var params = @[("id", $threadId)]
      if postId.isSome():
        params.add(("anchor", $postId.get()))
      let uri = makeUri("posts.json", params)
      ajaxGet(uri, @[], (s: int, r: kstring) => onPostList(s, r, postId))

      return buildHtml(tdiv(class="loading loading-lg"))

    let list = state.list.get()
    result = buildHtml():
      section(class="container grid-xl"):
        tdiv(class="title"):
          p(): text list.thread.topic
          if list.thread.isLocked:
            italic(class="fas fa-lock fa-xs",
                   title="Thread cannot be replied to")
            text "Locked"
          if list.thread.isModerated:
            italic(class="fas fa-eye-slash fa-xs",
                   title="Thread is moderated")
            text "Moderated"
          if list.thread.isSolved:
            italic(class="fas fa-check-square fa-xs",
                   title="Thread has a solution")
            text "Solved"
          render(list.thread.category)
        tdiv(class="posts"):
          var prevPost: Option[Post] = none[Post]()
          for i, post in list.posts:
            if prevPost.isSome:
              genTimePassed(prevPost.get(), some(post), false)
            if post.moreBefore.len > 0:
              genLoadMore(post, i)
            genPost(post, list.thread, isLoggedIn)
            prevPost = some(post)

          if prevPost.isSome:
            genTimePassed(prevPost.get(), none[Post](), true)

          tdiv(id="thread-buttons"):
            button(class="btn btn-secondary",
                   onClick=(e: Event, n: VNode) =>
                         onReplyClick(e, n, none[Post]())):
              italic(class="fas fa-reply")
              text " Reply"

          render(state.replyBox, list.thread, state.replyingTo, false)