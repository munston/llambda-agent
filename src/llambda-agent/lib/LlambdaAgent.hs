module LlambdaAgent
where

import Gremlins.Agent
import Gremlins.Types
import LlambdaAgent.EffectsRing

go :: String -> [String] -> IO String
go "effects-ring-check" [] = pure effectsRingSelfCheck
go option args = agentGo option args

verifiedRoutes :: [VerifiedRoute]
verifiedRoutes =
  [ VerifiedRoute {routeOption = "--help", routeArgs = [], routePrecog = "\\s -> \"llambda-agent\" `isInfixOf` s"}
  , VerifiedRoute {routeOption = "stack", routeArgs = [], routePrecog = "\\s -> \"gremlins client\" `isInfixOf` s && \"dexter\" `isInfixOf` s"}
  , VerifiedRoute {routeOption = "environment-setup", routeArgs = [], routePrecog = "\\s -> \"environment-setup: ok\" `isInfixOf` s"}
  , VerifiedRoute {routeOption = "effects-ring-check", routeArgs = [], routePrecog = "\\s -> \"effects-ring-check: ok\" `isInfixOf` s"}
  , VerifiedRoute {routeOption = "match", routeArgs = [], routePrecog = "\\s -> \"profile-source:\" `isInfixOf` s"}
  , VerifiedRoute {routeOption = "auto-assign", routeArgs = ["gan-compile-002"], routePrecog = "\\s -> \"workboard-auto-assign:\" `isInfixOf` s || \"workboard-assign:\" `isInfixOf` s"}
  , VerifiedRoute {routeOption = "realize", routeArgs = ["gan-compile-001"], routePrecog = "\\s -> \"workboard-realize: ok\" `isInfixOf` s && \"workboard-dispatch: ok\" `isInfixOf` s"}
  , VerifiedRoute {routeOption = "turn", routeArgs = ["gan-compile-003"], routePrecog = "\\s -> \"GREMLINS_TURN_V1\" `isInfixOf` s && \"workboard-turn:\" `isInfixOf` s"}
  , VerifiedRoute {routeOption = "cog-atlas-echo-pipeline", routeArgs = [], routePrecog = "\\s -> \"cog-echo-pipeline: ok\" `isInfixOf` s && \"ATLAS_RESULT_V2\" `isInfixOf` s"}
  , VerifiedRoute {routeOption = "evolution-status", routeArgs = [], routePrecog = "\\s -> \"evolution-session:\" `isInfixOf` s"}
  , VerifiedRoute {routeOption = "institution-status", routeArgs = [], routePrecog = "\\s -> \"institution-status:\" `isInfixOf` s"}
  , VerifiedRoute {routeOption = "notebook", routeArgs = [], routePrecog = "\\s -> \"design-notebook:\" `isInfixOf` s"}
  , VerifiedRoute {routeOption = "agents", routeArgs = [], routePrecog = "\\s -> \"agents:\" `isInfixOf` s && \"source:\" `isInfixOf` s"}
  , VerifiedRoute {routeOption = "mogwai", routeArgs = [], routePrecog = "\\s -> \"agent-progression:\" `isInfixOf` s && \"statuses: pre-gremlin, gremlin, and mogwai\" `isInfixOf` s"}
  , VerifiedRoute {routeOption = "academy-curriculum", routeArgs = [], routePrecog = "\\s -> \"mogwai-qualification-suite\" `isInfixOf` s && \"Accelerate taskflow\" `isInfixOf` s"}
  , VerifiedRoute {routeOption = "academy-closed-loop-curriculum", routeArgs = [], routePrecog = "\\s -> \"elliot-closed-loop-foundation\" `isInfixOf` s && \"LocationScout\" `isInfixOf` s"}
  , VerifiedRoute {routeOption = "academy", routeArgs = [], routePrecog = "\\s -> \"mogwai promotion requires the persisted multi-axis qualification suite\" `isInfixOf` s"}
  , VerifiedRoute {routeOption = "academy-teachers", routeArgs = [], routePrecog = "\\s -> \"academy-teachers:\" `isInfixOf` s && \"selection:\" `isInfixOf` s"}
  , VerifiedRoute {routeOption = "progression-status", routeArgs = ["gizmo"], routePrecog = "\\s -> \"progression-status:\" `isInfixOf` s && \"policy-hash:\" `isInfixOf` s"}
  , VerifiedRoute {routeOption = "ring-study-results", routeArgs = [], routePrecog = "\\s -> \"ring-study-results:\" `isInfixOf` s"}
  , VerifiedRoute {routeOption = "compile-drills", routeArgs = [], routePrecog = "\\s -> \"drill-hs-701\" `isInfixOf` s"}
  , VerifiedRoute {routeOption = "coding-challenges", routeArgs = [], routePrecog = "\\s -> \"code-hs-015\" `isInfixOf` s"}
  , VerifiedRoute {routeOption = "economy-prices", routeArgs = [], routePrecog = "\\s -> \"nemotron-turn: free\" `isInfixOf` s && \"deep-ring-turn: free\" `isInfixOf` s"}
  , VerifiedRoute {routeOption = "development-state", routeArgs = ["missing-development-job"], routePrecog = "\\s -> \"development-state: unknown job:\" `isInfixOf` s"}
  , VerifiedRoute {routeOption = "workflow-store", routeArgs = [], routePrecog = "\\s -> \"workflow-store: ok\" `isInfixOf` s && \"stages:\" `isInfixOf` s"}
  , VerifiedRoute {routeOption = "workflow-state", routeArgs = ["missing-workflow-id"], routePrecog = "\\s -> \"workflow-state: workflow not found:\" `isInfixOf` s"}
  , VerifiedRoute {routeOption = "memory-query", routeArgs = ["operational institution", "--max", "3"], routePrecog = "\\s -> \"memory-query: ok\" `isInfixOf` s && \"candidate-count:\" `isInfixOf` s"}
  , VerifiedRoute {routeOption = "memory-pack", routeArgs = ["operational institution", "--max", "3"], routePrecog = "\\s -> \"memory-pack: ok\" `isInfixOf` s"}
  , VerifiedRoute {routeOption = "firm-academy-curriculum", routeArgs = [], routePrecog = "\\s -> \"firm-foundation-workflow\" `isInfixOf` s && \"production workflow\" `isInfixOf` s"}
  , VerifiedRoute {routeOption = "firm-academy-ledger", routeArgs = [], routePrecog = "\\s -> \"firm-academy-ledger:\" `isInfixOf` s"}
  , VerifiedRoute {routeOption = "workflow-programs", routeArgs = [], routePrecog = "\\s -> \"gan-program-001\" `isInfixOf` s && \"only landed implementation stages\" `isInfixOf` s"}
  , VerifiedRoute {routeOption = "atlas", routeArgs = ["batch-learning"], routePrecog = "\\s -> \"batch-learning:\" `isInfixOf` s && \"learned-work-limit:\" `isInfixOf` s"}
  ]

routeOptouts :: [RouteOptout]
routeOptouts =
  [ RouteOptout {routeOptoutOption = "dispatch", routeOptoutReason = "requires rank-aware gremlins realization batch"}
  , RouteOptout {routeOptoutOption = "agent-enrol", routeOptoutReason = "creates a persisted pre-gremlin identity"}
  , RouteOptout {routeOptoutOption = "agent-traits-set", routeOptoutReason = "changes a persisted agent policy for a controlled comparison"}
  , RouteOptout {routeOptoutOption = "academy-trial", routeOptoutReason = "runs live model-backed progression trials and may promote an agent"}
  , RouteOptout {routeOptoutOption = "academy-closed-loop-exam", routeOptoutReason = "runs live Nemotron intelligence through Gremlin and real Elliot onepush/landing"}
  , RouteOptout {routeOptoutOption = "academy-ring-study", routeOptoutReason = "runs repeated live controlled ring configurations; selection requires at least three repetitions and persists evidence"}
  , RouteOptout {routeOptoutOption = "academy-teacher-qualify", routeOptoutReason = "runs a live teacher plan and independent qualification assessment"}
  , RouteOptout {routeOptoutOption = "academy-teaching-start", routeOptoutReason = "creates a persisted client-owned teaching session"}
  , RouteOptout {routeOptoutOption = "academy-teaching-steer", routeOptoutReason = "persists direct initiating-client guidance"}
  , RouteOptout {routeOptoutOption = "academy-teaching-step", routeOptoutReason = "runs live qualified-Mogwai policy formation and assessment"}
  , RouteOptout {routeOptoutOption = "academy-teaching-apply", routeOptoutReason = "applies an explicitly approved trainee policy"}
  , RouteOptout {routeOptoutOption = "academy-teaching-revert", routeOptoutReason = "restores a persisted baseline policy"}
  , RouteOptout {routeOptoutOption = "academy-teaching-assess", routeOptoutReason = "runs a live Academy consequence trial"}
  , RouteOptout {routeOptoutOption = "ring-study-report", routeOptoutReason = "writes CSV and HTML graph reports from persisted evidence"}
  , RouteOptout {routeOptoutOption = "compile-run", routeOptoutReason = "runs the assigned gremlin's live Elliot/Dexter compile loop"}
  , RouteOptout {routeOptoutOption = "development-submit", routeOptoutReason = "defaults to implementation requiring an accepted Elliot landing; --repair permits clean-build verification; terminal failed workflows are replaced on retry"}
  , RouteOptout {routeOptoutOption = "development-continue", routeOptoutReason = "resumes a persisted live compiler-assistance job"}
  , RouteOptout {routeOptoutOption = "atlas-dispatch", routeOptoutReason = "requires atlas batch dispatch"}
  , RouteOptout {routeOptoutOption = "workboard-dispatch", routeOptoutReason = "requires atlas batch dispatch"}
  , RouteOptout {routeOptoutOption = "assign", routeOptoutReason = "mutates workboard state"}
  , RouteOptout {routeOptoutOption = "submit-job", routeOptoutReason = "mutates the persisted world job ledger"}
  , RouteOptout {routeOptoutOption = "submit-jobs-file", routeOptoutReason = "mutates the persisted world job ledger"}
  , RouteOptout {routeOptoutOption = "evolution-start", routeOptoutReason = "allocates a persisted provider-call session"}
  , RouteOptout {routeOptoutOption = "evolution-step", routeOptoutReason = "dispatches live Atlas batches"}
  , RouteOptout {routeOptoutOption = "evolution-run", routeOptoutReason = "dispatches live Atlas batches"}
  , RouteOptout {routeOptoutOption = "evolution-close", routeOptoutReason = "mutates the persisted evolution session"}
  , RouteOptout {routeOptoutOption = "institution-start", routeOptoutReason = "starts persisted institutional scheduling"}
  , RouteOptout {routeOptoutOption = "institution-step", routeOptoutReason = "advances one live institutional lane"}
  , RouteOptout {routeOptoutOption = "institution-run", routeOptoutReason = "runs bounded live institutional cycles"}
  , RouteOptout {routeOptoutOption = "institution-stop", routeOptoutReason = "stops persisted institutional scheduling"}
  , RouteOptout {routeOptoutOption = "notebook-record", routeOptoutReason = "persists design or snippet knowledge"}
  , RouteOptout {routeOptoutOption = "workflow-create", routeOptoutReason = "runs live Dexter Accelerate planning and persists an accepted workflow"}
  , RouteOptout {routeOptoutOption = "workflow-create-program", routeOptoutReason = "persists an accepted catalogue dependency graph for firm execution"}
  , RouteOptout {routeOptoutOption = "workflow-advance", routeOptoutReason = "assigns a firm member and runs live Gremlin/Dexter/Elliot stage execution"}
  , RouteOptout {routeOptoutOption = "workflow-continue", routeOptoutReason = "runs sequential live Gremlin/Dexter/Elliot workflow stages"}
  , RouteOptout {routeOptoutOption = "workflow-revise", routeOptoutReason = "runs live Dexter replanning and supersedes unverified stages"}
  , RouteOptout {routeOptoutOption = "workflow-replan", routeOptoutReason = "runs live Dexter replanning and persists a new plan version"}
  , RouteOptout {routeOptoutOption = "workflow-reassign", routeOptoutReason = "mutates persisted firm stage assignment"}
  , RouteOptout {routeOptoutOption = "workflow-link-workboard", routeOptoutReason = "links a persisted parent workboard job to a workflow"}
  , RouteOptout {routeOptoutOption = "firm-academy-run", routeOptoutReason = "uses the production live workflow executor without an academy landing shortcut"}
  ]

