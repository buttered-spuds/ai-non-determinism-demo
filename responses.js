// responses.js
// Pre-written response pools for the AI Nondeterminism Simulator
// Responses are tagged with a similarity level relative to the first "canonical" response:
//   "equivalent"  → semantically equivalent, different wording (green)
//   "similar"     → overlapping meaning, noticeably different phrasing (yellow)
//   "divergent"   → same topic but significantly different content/angle (red)
//
// Temperature pools: "low" (0–0.33), "medium" (0.34–0.66), "high" (0.67–1.0)

const RESPONSES = {
  // ─── Main demo prompt ────────────────────────────────────────────────────────
  main: {
    prompt: "Summarise the benefits of automated testing in one sentence.",
    canonical: "Automated testing saves time by catching bugs early and reducing manual effort.",

    low: [
      { text: "Automated testing saves time by catching bugs early and reducing manual effort.", similarity: "equivalent" },
      { text: "Automated testing saves time by finding bugs early and cutting down on manual work.", similarity: "equivalent" },
      { text: "Automated testing saves development time by catching defects early and minimising manual testing effort.", similarity: "equivalent" },
      { text: "Automated tests save time by surfacing bugs early and reducing the need for manual checking.", similarity: "equivalent" },
      { text: "Automated testing reduces costs by identifying bugs early, minimising the manual effort required.", similarity: "equivalent" },
      { text: "Automated testing saves teams time by catching regressions early and reducing reliance on manual verification.", similarity: "equivalent" },
      { text: "By catching bugs early, automated testing saves time and significantly reduces the burden of manual testing.", similarity: "equivalent" },
      { text: "Automated testing cuts time and effort by surfacing defects early in the development cycle.", similarity: "equivalent" },
      { text: "Automated testing saves time and reduces manual effort by catching bugs before they reach production.", similarity: "equivalent" },
      { text: "Automated testing saves time by detecting bugs early in development and reducing the need for repetitive manual checks.", similarity: "equivalent" },
    ],

    medium: [
      { text: "Test automation accelerates delivery by providing fast, repeatable feedback on code quality.", similarity: "similar" },
      { text: "By automating repetitive checks, teams can ship software faster with greater confidence.", similarity: "similar" },
      { text: "Automation reduces human error, increases coverage, and frees testers for exploratory work.", similarity: "similar" },
      { text: "Automated testing improves reliability and speed by continuously validating that code changes don't break existing behaviour.", similarity: "similar" },
      { text: "Automated tests give teams confidence to refactor and release frequently by instantly flagging regressions.", similarity: "similar" },
      { text: "Test automation enables rapid, repeatable verification of software behaviour, reducing the cost of quality assurance.", similarity: "similar" },
      { text: "Automated testing boosts efficiency by running thousands of checks in minutes, freeing engineers for higher-value work.", similarity: "similar" },
      { text: "Continuous automated testing provides a safety net that lets teams move fast without sacrificing code quality.", similarity: "similar" },
      { text: "Automation removes bottlenecks in the testing process, enabling faster release cycles and more predictable quality.", similarity: "similar" },
      { text: "Automated testing reduces QA overhead while increasing confidence by providing consistent, repeatable test execution.", similarity: "similar" },
    ],

    high: [
      { text: "A robust automated test suite is the foundation of a healthy CI/CD pipeline and a culture of engineering excellence.", similarity: "divergent" },
      { text: "Without automated testing, every deployment is a leap of faith — with it, your regression risk drops dramatically.", similarity: "divergent" },
      { text: "Automated testing shifts quality left, embedding verification into every stage of development rather than bolting it on at the end.", similarity: "divergent" },
      { text: "The real value of automated testing isn't catching bugs — it's giving developers the psychological safety to refactor boldly.", similarity: "divergent" },
      { text: "Test automation is a force multiplier: a single well-written test can protect millions of users from a critical regression for years.", similarity: "divergent" },
      { text: "Investing in automated testing compounds over time — every test written today pays dividends in prevented incidents for years to come.", similarity: "divergent" },
      { text: "Automated testing democratises quality assurance by making comprehensive validation accessible to every team regardless of size.", similarity: "divergent" },
      { text: "Rather than a cost centre, a mature automated test suite is a strategic asset that accelerates every future feature you build.", similarity: "divergent" },
      { text: "Automated testing changes the economics of software delivery: bugs found in CI cost 10× less to fix than bugs found in production.", similarity: "divergent" },
      { text: "A green test suite is the closest thing software has to a guarantee — it's the proof that your code does what you think it does.", similarity: "divergent" },
    ],
  },

  // ─── Hallucination demo ───────────────────────────────────────────────────────
  hallucination: {
    prompt: "Who invented the World Wide Web, and in what year?",
    correct: { text: "The World Wide Web was invented by Tim Berners-Lee in 1989.", label: "correct" },
    responses: [
      { text: "The World Wide Web was invented by Tim Berners-Lee in 1989.", label: "correct" },
      { text: "The World Wide Web was invented by Tim Berners-Lee in 1991.", label: "wrong-detail", note: "Wrong year — the proposal was 1989, the first public website launched 1991." },
      { text: "Tim Berners-Lee and Robert Cailliau co-invented the World Wide Web at CERN in 1989.", label: "misleading", note: "Cailliau co-authored the proposal but is not credited as co-inventor of the Web." },
      { text: "The World Wide Web was created by Tim Berners-Lee in 1990 while working at CERN.", label: "wrong-detail", note: "Slightly wrong year — the original proposal was written in 1989." },
      { text: "The internet was invented by Tim Berners-Lee in 1989.", label: "wrong-concept", note: "Confuses the World Wide Web with the internet, which predates it by decades." },
      { text: "Tim Berners-Lee invented the World Wide Web in 1989, publishing the first website in 1993.", label: "wrong-detail", note: "The first website went live in 1991, not 1993." },
      { text: "The World Wide Web was invented by Tim Berners-Lee in 1989.", label: "correct" },
      { text: "Tim Berners-Lee invented the World Wide Web in 1989 as a way to share information at CERN.", label: "correct" },
      { text: "The World Wide Web was proposed by Tim Berners-Lee in 1989 and developed further by Vint Cerf.", label: "wrong-detail", note: "Vint Cerf co-invented TCP/IP and is considered a father of the internet, not the Web." },
      { text: "Tim Berners-Lee invented the World Wide Web in 1992.", label: "wrong-detail", note: "Wrong year — the proposal was 1989." },
    ],
  },
};
