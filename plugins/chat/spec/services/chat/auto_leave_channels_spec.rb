# frozen_string_literal: true

RSpec.describe Chat::AutoLeaveChannels do
  describe ".call" do
    subject(:job) { described_class.call }

    let(:noop) { ->(*) {} }

    # Disable all the event handlers by the chat plugin
    # Had to noop all the event handlers because of the "DiscourseEvent registrations were not cleaned up" spec
    before do
      %i[
        site_setting_changed
        group_destroyed
        user_seen
        user_confirmed_email
        user_added_to_group
        user_removed_from_group
        category_updated
      ].each { |event| DiscourseEvent.events[event] = [noop] * DiscourseEvent.events[event].size }
    end

    context "when chat is disabled" do
      before { SiteSetting.chat_enabled = false }

      it { is_expected.to fail_a_policy(:chat_enabled?) }
    end

    context "when chat is enabled" do
      before { SiteSetting.chat_enabled = true }

      context "when users are not allowed to chat" do
        fab!(:uccm_1) { Fabricate(:user_chat_channel_membership) }
        fab!(:uccm_2) { Fabricate(:user_chat_channel_membership_for_dm) }

        it "removes all their memberships" do
          expect { job }.to change { ::Chat::UserChatChannelMembership.count }.from(2).to(0)
        end

        it "publishes automatically removed users" do
          ::Chat::Action::PublishAutoRemovedUser
            .expects(:call)
            .once
            .with(
              event: :some_event_name,
              users_removed_map: {
                uccm_1.chat_channel_id => [uccm_1.user_id],
                uccm_2.chat_channel_id => [uccm_2.user_id],
              },
            )

          described_class.call(event: :some_event_name)
        end
      end

      context "when everyone is allowed to chat" do
        fab!(:uccm) { Fabricate(:user_chat_channel_membership) }

        before { SiteSetting.chat_allowed_groups = Group::AUTO_GROUPS[:everyone] }

        it "does not remove memberships" do
          expect { job }.not_to change { ::Chat::UserChatChannelMembership.count }.from(1)
        end
      end

      context "when the category's permission changes" do
        fab!(:user) { Fabricate(:user, trust_level: 1) }
        fab!(:group) { Fabricate(:group) }
        fab!(:category) { Fabricate(:private_category, group:) }
        fab!(:chat_channel) { Fabricate(:chat_channel, chatable: category) }
        fab!(:uccm) { Fabricate(:user_chat_channel_membership, user:, chat_channel:) }

        before { group.add(user) }

        context "when there's no permission anymore" do
          before { CategoryGroup.where(category:).destroy_all }

          it "removes user membership" do
            expect { job }.to change { ::Chat::UserChatChannelMembership.count }.from(1).to(0)
          end

          it "publishes automatically removed users" do
            ::Chat::Action::PublishAutoRemovedUser
              .expects(:call)
              .once
              .with(event: nil, users_removed_map: { uccm.chat_channel_id => [uccm.user_id] })

            job
          end

          it "does not remove bot membership" do
            bot = Fabricate(:bot, trust_level: 1)
            Fabricate(:user_chat_channel_membership, user: bot, chat_channel:)

            expect { job }.not_to change {
              ::Chat::UserChatChannelMembership.where(user: bot).count
            }.from(1)
          end

          it "does not remove moderator membership" do
            user.update!(moderator: true)

            expect { job }.not_to change { ::Chat::UserChatChannelMembership.count }.from(1)
          end

          it "does not remove admin membership" do
            user.update!(admin: true)

            expect { job }.not_to change { ::Chat::UserChatChannelMembership.count }.from(1)
          end

          context "with another category/channel/user" do
            fab!(:user_2) { Fabricate(:user, trust_level: 1) }
            fab!(:category_2) { Fabricate(:private_category, group:) }
            fab!(:chat_channel_2) { Fabricate(:chat_channel, chatable: category_2) }
            fab!(:uccm_2) do
              Fabricate(:user_chat_channel_membership, user: user_2, chat_channel: chat_channel_2)
            end

            it "supports filtering by user_id" do
              expect { described_class.call(user_id: user.id) }.to change {
                ::Chat::UserChatChannelMembership.count
              }.from(2).to(1)
            end

            it "supports filtering by channel_id" do
              expect { described_class.call(channel_id: chat_channel.id) }.to change {
                ::Chat::UserChatChannelMembership.count
              }.from(2).to(1)
            end

            it "supports filtering by category_id" do
              expect { described_class.call(category_id: category.id) }.to change {
                ::Chat::UserChatChannelMembership.count
              }.from(2).to(1)
            end
          end
        end

        it "removes membership when permission is 'readonly'" do
          CategoryGroup.find_by(category:, group:).update!(
            permission_type: CategoryGroup.permission_types[:readonly],
          )

          expect { job }.to change { ::Chat::UserChatChannelMembership.count }.from(1).to(0)
        end

        it "does not remove membership when permission is 'create_post'" do
          CategoryGroup.find_by(category:, group:).update!(
            permission_type: CategoryGroup.permission_types[:create_post],
          )

          expect { job }.not_to change { ::Chat::UserChatChannelMembership.count }.from(1)
        end

        it "does not remove membership when permission is 'full'" do
          CategoryGroup.find_by(category:, group:).update!(
            permission_type: CategoryGroup.permission_types[:full],
          )

          expect { job }.not_to change { ::Chat::UserChatChannelMembership.count }.from(1)
        end
      end
    end
  end
end
