# Chat It

Assistant conversationnel qui parle à un serveur LocalAI, par écrit ou à la voix, et garde l'historique localement.

## Language

**Conversation**:
Fil titré et persisté de messages entre l'utilisateur et l'assistant ; unité de l'historique, qu'elle soit écrite ou parlée.
_Avoid_: Chat, discussion, session, thread

**Chat**:
L'acte d'interroger le modèle de langage (modèle de chat, complétion de chat), jamais le fil persisté.
_Avoid_: Conversation (pour ce sens)

**Mode vocal**:
Écran plein format où l'utilisateur dialogue à la voix avec l'assistant, sans clavier ; ses tours s'ajoutent à la Conversation courante. Il continue quand l'app passe en arrière-plan, jusqu'à ce que l'utilisateur le quitte.
_Avoid_: Appel, session vocale, voice chat

**Tour**:
Une prise de parole de l'utilisateur ou de l'assistant dans le Mode vocal ; chaque Tour devient un message de la Conversation.
_Avoid_: Tour de parole, utterance, réplique

**Interruption**:
Prise de parole de l'utilisateur pendant le Tour de l'assistant, qui coupe sa lecture et sa génération ; seul ce qui a été prononcé reste dans la Conversation, marqué comme interrompu.
_Avoid_: Barge-in, coupure

**Orbe**:
Cercle animé au centre du Mode vocal qui pulse au rythme de la voix de celui qui parle et reflète l'état de l'assistant (écoute, réflexion, parole).
_Avoid_: Bulle, avatar, visualiseur, effet vibratoire

**Signal d'écoute**:
Courte vocalisation de l'assistant (« hmm », « d'accord… ») qui comble le silence pendant qu'il prépare sa réponse ; ne fait pas partie de la Conversation.
_Avoid_: Backchannel, filler, mimique

**Style oral**:
Manière de répondre propre au Mode vocal : phrases courtes et parlées, sans mise en forme écrite.
_Avoid_: Mode parlé, mimique

**Dictée**:
Saisie d'un message par la voix dans la barre de saisie écrite, hors Mode vocal.
_Avoid_: Mode vocal (pour ce sens)
