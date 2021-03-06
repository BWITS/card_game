require 'card_game/card'
require 'card_game/ordering'
require 'card_game/trick'
require 'card_game/game'

require 'card_game/five_hundred/state'

module CardGame
  # Utility methods for modeling five hundred.
  class FiveHundred
    # @private
    OPPOSITES = {
      Suit.hearts   => Suit.diamonds,
      Suit.diamonds => Suit.hearts,
      Suit.clubs    => Suit.spades,
      Suit.spades   => Suit.clubs,
    }

    # Returns the winning card of a given trick, accounting for trumps, bowers,
    # and the Joker.
    #
    # @param trick [Trick]
    # @return [Card]
    def self.winning_card(trick)
      led = trick.cards.first

      raise(ArgumentError, "Trick must contain at least one card") unless led

      opposite = OPPOSITES.fetch(trick.trump) { Suit.none }
      left_bower  = Card.new(rank: Rank.jack, suit: opposite)
      right_bower = Card.new(rank: Rank.jack, suit: trick.trump)
      joker       = Card.new(rank: Rank.joker, suit: Suit.none)

      trick.cards.sort_by(&Ordering.composite(
        Ordering.match(joker),
        Ordering.match(right_bower),
        Ordering.match(left_bower),
        Ordering.suit(trick.trump),
        Ordering.suit(led.suit),
        Ordering.by_rank(ALL_RANKS),
      )).last
    end

    # Creates a deck suitable for Five Hundred.
    #
    # @param players [Integer] The number of players. Must be between 3 and 6.
    # @return [Array<Card>]
    def self.deck(players: 4)
      joker = [Card.unsuited(Rank.joker)]

      ranks_for_colors = DECK_SPECIFICATION.fetch(players) {
        raise ArgumentError,
          "Only 3 to 6 players are supported, not #{players}"
      }

      joker + ALL_RANKS.product(Suit.all)
        .map {|rank, suit| Card.build(rank, suit) }
        .select {|card|
          ranks_for_colors.fetch(card.suit.color).include?(card.rank)
        }
    end

    make_ranks = -> r {
      r.map(&Rank.method(:numbered)) + Rank.faces + [Rank.ace]
    }

    # Deck specifications for different numbers of players.
    #
    # @private
    DECK_SPECIFICATION = {
      3 => {
        Color.red   => make_ranks.(7..10),
        Color.black => make_ranks.(7..10),
      },
      4 => {
        Color.red   => make_ranks.(4..10),
        Color.black => make_ranks.(5..10),
      },
      5 => {
        Color.red   => make_ranks.(2..10),
        Color.black => make_ranks.(2..10),
      },
      6 => {
        Color.red   => make_ranks.(2..13),
        Color.black => make_ranks.(2..12),
      }
    }

    # All known ranks.
    #
    # @private
    ALL_RANKS = DECK_SPECIFICATION.fetch(6)[Color.red]

    # State machine modeling the rules of Five Hundred. Create actions using
    # builder methods on the player objects stored in
    # {CardGame::FiveHundred::State}. Only actions from the priority player
    # are valid.
    #
    # Only "standard" bids are implemented (e.g. no Misère).
    #
    # @param players [Integer] the number of players.
    # @return [CardGame::Game]
    # @see State#players
    def self.play(players: 4)
      players = (1..players).map {|x| Player.new(position: x) }

      Game.new(Phase::Setup, State.initial(players))
    end

    # All actions that can be applied for a game of Five Hundred.
    module Action
      # @private
      class CoreBid < Game::Action
        include Comparable

        def <=>(other)
          key <=> other.key
        end
      end

      # A bid action. Currently does not handle mezzaire.
      #
      # @attr_reader number [Integer] number of tricks to win.
      # @attr_reader suit   [Suit] trump suit.
      class Bid < CoreBid
        values do
          attribute :number, Integer
          attribute :suit, Suit
        end

        # Construct a new bid.
        #
        # @param actor [Player]
        # @param number [Integer]
        # @param suit [Suit]
        def self.build(actor, number, suit)
          new(actor: actor, number: number, suit: suit)
        end

        # @private
        def key
          [score]
        end

        # Points that would be earned by this bid.
        #
        # @return [Integer]
        def score
          suit_score = [
            Suit.spades,
            Suit.clubs,
            Suit.diamonds,
            Suit.hearts,
            Suit.none
          ].index(suit) * 20 + 40

          (number - 6) * 100 + suit_score
        end

        # @return [String]
        def to_s
          "<Bid %s %i%s>" % [actor, number, suit]
        end
        alias_method :inspect, :to_s

        # @return [String]
        def pretty_print(pp)
          pp.text(to_s)
        end
      end

      # Pass priority without placing a bid. Only valid during bidding phase.
      class Pass < CoreBid
        # @private
        def key
          [0]
        end
      end

      # Play a card into the current trick. Only valid during round phase.
      #
      # @attr_reader card [Card] card from player's hand.
      class Play < Game::Action
        values do
          attribute :card, Card
        end
      end

      # Place cards back into the kitty. Only valid during kitty phase.
      #
      # @attr_reader cards [Set<Card>] cards from player's hand.
      class Kitty < Game::Action
        values do
          attribute :cards, [Card]
        end
      end
    end

    # An individual player in the game. Builder methods construct
    # {CardGame::Game::Action} subclasses suitable for passing to
    # {CardGame::Game#apply}.
    class Player < Game::Player
      # @param n [Integer] number of tricks to win
      # @param suit [Suit] trump suit
      # @return [Action::Bid]
      def bid(n, suit)
        Action::Bid.build(self, n, suit)
      end

      # @return [Action::Pass]
      def pass
        Action::Pass.build(self)
      end

      # @param card [Card] card from player's hand.
      # @return [Action::Play]
      def play(card)
        Action::Play.new(actor: self, card: card)
      end

      # @param cards [Set<Card>] cards from the player's hand to place back
      #                          into kitty.
      # @return [Action::Kitty]
      def kitty(cards)
        Action::Kitty.new(actor: self, cards: cards)
      end
    end

    # @private
    module Phase
      Abstract = CardGame::Game::Phase

      class Setup < Abstract
        def enter
          state
            .give_deal(state.players.first) # TODO: sample, store seed in state
        end

        def transition
          NewRound
        end
      end

      class NewRound < Abstract
        def enter
          deck = FiveHundred.deck(players: state.players.size)

          state
            .deal(deck)
            .advance_dealer
            .give_priority(state.dealer)
            .place_bid(Action::Pass.new({}))
        end

        def transition
          Bidding
        end
      end

      module RequirePriority
        def apply(action)
          super

          if action.actor != state.priority
            raise "#{action.actor} may not act, #{state.priority} has priority"
          end
        end
      end

      class Bidding < Abstract
        include RequirePriority

        def apply(action)
          super

          if action > state.bid
            state.advance.place_bid(action)
          else
            state.advance
          end
        end

        def transition
          Kitty if state.bid.actor == state.priority
        end
      end

      class Kitty < Abstract
        include RequirePriority

        def enter
          state.move_kitty_to_hand
        end

        def apply(action)
          super

          state.move_cards_to_kitty(action.cards)
        end

        def transition
          Phase::Trick if state.kitty.size == 3
        end
      end

      class Trick < Abstract
        include RequirePriority

        def enter
          state.new_trick
        end

        def exit
          # TODO: Figure out a way to clean this up
          card = FiveHundred.winning_card(
            CardGame::Trick.build(state.trick.to_a, state.bid.suit)
          )
          i = state.trick.to_a.index(card)

          winner = state.player_relative_to(state.priority, i)

          state
            .won_trick(winner)
            .give_priority(winner)
        end

        def apply(action)
          super

          case action
          when Action::Play
            state

            if !state.priority_hand.include?(action.card)
              raise "#{action.card} is not in hand of #{action.actor}"
            end

            state
              .add_card_to_trick(action.card)
              .advance
          end
        end

        def transition
          return Scoring if state.hands.values.all?(&:empty?)
          return Trick if state.trick.size == state.players
        end
      end

      class Scoring < Abstract
        def enter
          bidding_team = state.team_for(state.bid.actor)
          tricks_won = state.tricks_won_by(bidding_team)

          mod = if tricks_won >= state.bid.number
            1
          else
            -1
          end

          new_state = state.adjust_score(bidding_team, state.bid.score * mod)

          opposing_team = new_state.players - bidding_team
          tricks_won = new_state.tricks_won_by(opposing_team)

          new_state.adjust_score(opposing_team, tricks_won * 10)
        end

        def exit
          state.clear_tricks
        end

        def transition
          if state.scores.values.any? {|x| !(-500..500).cover?(x) }
            Completed
          else
            NewRound
          end
        end
      end

      class Completed < Abstract
      end
    end
  end
end
