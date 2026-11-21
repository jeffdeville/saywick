# App Store preparation

`site/` is a static website prepared for the proposed appstore.workhand.ai host.
Serve the folder root (for example, `python3 -m http.server --directory Release/site`).
The pages are not deployed.
`metadata/en-US.json` contains draft listing copy and proposed URLs, not live links.

## Support promise

Give users a working way to report issues and ask questions. The owner replies as time permits, with no guaranteed response time. The [draft support page](site/saywick/support/index.html) still needs a real contact before publication.

## Support triage

When a report arrives, establish what the user tried, what happened, and what they expected. Answer how-to questions directly. If the product behaves as intended but the workflow or instructions are hard to follow, identify the usability issue. A report can warrant both an answer and a usability improvement. For a confirmed defect, fix it and follow the product’s [verification](../docs/device-testing.md#required-physical-iphone-verification) and [release process](../docs/app-store-release.md#release-authority). A separate issue tracker is optional. The intended public contact is a form on the Saywick website. A handler on infrastructure the owner controls sends each report and any optional reply email directly to the owner’s private Slack support channel via incoming webhook. Keep the webhook URL server-side. This route excludes third-party form providers. Users interact with the website and do not need Slack accounts. The form is pending implementation. The form must accept a bug report with the email field blank. Label the email field optional and explain that users can leave an address if they want a reply. The owner can reply by email as time permits. Reports in the private support channel, including any email addresses submitted with them, follow the Slack workspace’s normal retention policy.

## Optional support attachments

At launch, users may attach screenshots and Saywick diagnostics to a report. The owner-controlled handler can forward files to the private support channel using Slack’s authenticated file-upload API. The incoming webhook handles text. Keep Slack credentials on the server. A separate service to hold or screen uploads is deferred until security or operational needs justify it.

Screenshots can show personal content, and diagnostics can include device and process details. Before launch, verify delivery with non-sensitive samples of both types, check rejected or incomplete uploads, and give users a chance to review what they submit. The form and file delivery still require implementation. [Slack file uploads](https://docs.slack.dev/messaging/working-with-files/)

## Draft changes

Codex may update draft listing, privacy, and support copy when the edit reflects verified app behavior or an owner-approved promise. Ask the owner before adding any new public commitment. Describe an approved but unimplemented feature as planned whenever it appears in draft copy.

## Before publication

Check each changed claim in the listing, privacy policy, and support materials against the specific build users will receive. Record the build identifier and the evidence for the claim. Test each changed link and contact method from the material being published. For a support address or form, verify that a test inquiry reaches the intended destination.

## Publication approval

Prepare and verify the draft, then present the verified changes to the owner for explicit approval before publishing. Obtain approval for each publication, including routine corrections to the website, its privacy or support pages, and the App Store listing.

## After public launch

Starting at public launch, check the published support contact daily to confirm an inquiry can reach the owner. Put this check into operation once the contact is live.

When a release goes out to users, use its [changelog entry](CHANGELOG.md) to identify which website pages and App Store listing details need updating. Prepare the affected drafts, verify them against the released build, and obtain approval for each publication. Page reviews are release-driven. Routine scheduled page checks are unnecessary.

[Engineering guide](../docs/engineering.md)
