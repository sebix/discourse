# frozen_string_literal: true

RSpec.describe Chat::AutoJoinChannels do
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
      let(:trust_level) { 1 } # SiteSetting.chat_allowed_groups defaults to admins, moderators, and TL1 users
      let(:last_seen_at) { 5.minutes.ago } # Users must have been seen "recently" to be auto-joined to a channel

      fab!(:public_category) { Fabricate(:category) }
      fab!(:private_category) { Fabricate(:category, read_restricted: true) }

      fab!(:private_group_readonly) { Fabricate(:group) }
      fab!(:private_group_create_post) { Fabricate(:group) }
      fab!(:private_group_full) { Fabricate(:group) }

      fab!(:private_category_group_readonly) do
        Fabricate(
          :category_group,
          category: private_category,
          group: private_group_readonly,
          permission_type: CategoryGroup.permission_types[:readonly],
        )
      end

      fab!(:private_category_group_create_post) do
        Fabricate(
          :category_group,
          category: private_category,
          group: private_group_create_post,
          permission_type: CategoryGroup.permission_types[:create_post],
        )
      end

      fab!(:private_category_group_full) do
        Fabricate(
          :category_group,
          category: private_category,
          group: private_group_full,
          permission_type: CategoryGroup.permission_types[:full],
        )
      end

      before { SiteSetting.chat_enabled = true }

      context "with a non-auto joinable public channel" do
        fab!(:non_auto_joinable_public_channel) do
          Fabricate(:chat_channel, chatable: public_category)
        end

        let!(:user) { Fabricate(:user, trust_level:, last_seen_at:) }

        it "doesn't automatically join users" do
          expect { job }.not_to change { Chat::UserChatChannelMembership.count }.from(0)
        end
      end

      context "with an auto joinable public channel" do
        fab!(:auto_joinable_public_channel) do
          Fabricate(:chat_channel, chatable: public_category, auto_join_users: true)
        end

        it "automatically joins users" do
          2.times { Fabricate(:user, trust_level:, last_seen_at:) }

          expect { job }.to change { Chat::UserChatChannelMembership.count }.from(0).to(2)
        end

        it "automatically join users when everyone is allowed" do
          SiteSetting.chat_allowed_groups = [
            Group::AUTO_GROUPS[:everyone],
            Group::AUTO_GROUPS[:trust_level_3],
          ].join(",")

          Fabricate(:user, trust_level:, last_seen_at:)

          expect { job }.to change { Chat::UserChatChannelMembership.count }.from(0).to(1)
        end

        it "always automatically joins moderators" do
          SiteSetting.chat_allowed_groups = Fabricate(:group).id

          Fabricate(:user, trust_level:, last_seen_at:)
          Fabricate(:moderator, trust_level:, last_seen_at:)

          expect { job }.to change { Chat::UserChatChannelMembership.count }.from(0).to(1)
        end

        it "always automatically joins admins" do
          SiteSetting.chat_allowed_groups = Fabricate(:group).id

          Fabricate(:user, trust_level:, last_seen_at:)
          Fabricate(:admin, trust_level:, last_seen_at:)

          expect { job }.to change { Chat::UserChatChannelMembership.count }.from(0).to(1)
        end

        it "automatically follows the channel in automatic mode" do
          user = Fabricate(:user, trust_level:, last_seen_at:)

          expect { job }.to change {
            Chat::UserChatChannelMembership
              .where(user:, chat_channel: auto_joinable_public_channel)
              .where(following: true, join_mode: :automatic)
              .count
          }.from(0).to(1)
        end

        it "recalculates user count" do
          Fabricate(:user, trust_level:, last_seen_at:)

          ::Chat::ChannelMembershipManager.any_instance.expects(:recalculate_user_count).once

          job
        end

        it "publishes new channel to auto-joined users" do
          user = Fabricate(:user, trust_level:, last_seen_at:)

          ::Chat::Publisher
            .expects(:publish_new_channel)
            .once
            .with(auto_joinable_public_channel, [user.id])

          job
        end

        it "supports filtering down to a specific user" do
          user = Fabricate(:user, trust_level:, last_seen_at:)
          Fabricate(:user, trust_level:, last_seen_at:)

          expect { described_class.call(user_id: user.id) }.to change {
            Chat::UserChatChannelMembership.count
          }.from(0).to(1)
        end

        it "supports filtering down to a specific channel" do
          Fabricate(:chat_channel, chatable: public_category, auto_join_users: true)

          Fabricate(:user, trust_level:, last_seen_at:)

          expect { described_class.call(channel_id: auto_joinable_public_channel.id) }.to change {
            Chat::UserChatChannelMembership.count
          }.from(0).to(1)
        end

        it "supports filtering down to a specific public category" do
          Fabricate(:chat_channel, chatable: Fabricate(:category), auto_join_users: true)

          Fabricate(:user, trust_level:, last_seen_at:)

          expect { described_class.call(category_id: public_category.id) }.to change {
            Chat::UserChatChannelMembership.count
          }.from(0).to(1)
        end

        it "doesn't automatically join users who have chat disabled" do
          user = Fabricate(:user, trust_level:, last_seen_at:)
          user.user_option.update!(chat_enabled: false)

          expect { job }.not_to change { Chat::UserChatChannelMembership.count }.from(0)
        end

        it "doesn't automatically join bots" do
          Fabricate(:bot, trust_level:, last_seen_at:)

          expect { job }.not_to change { Chat::UserChatChannelMembership.count }.from(0)
        end

        it "doesn't automatically join inactive users" do
          Fabricate(:user, trust_level:, last_seen_at:, active: false)

          expect { job }.not_to change { Chat::UserChatChannelMembership.count }.from(0)
        end

        it "doesn't automatically join staged users" do
          Fabricate(:user, trust_level:, last_seen_at:, staged: true)

          expect { job }.not_to change { Chat::UserChatChannelMembership.count }.from(0)
        end

        it "doesn't automatically join suspended users" do
          Fabricate(:user, trust_level:, last_seen_at:, suspended_till: 1.day.from_now)

          expect { job }.not_to change { Chat::UserChatChannelMembership.count }.from(0)
        end

        it "doesn't automatically join silenced users" do
          Fabricate(:user, trust_level:, last_seen_at:, silenced_till: 1.day.from_now)

          expect { job }.not_to change { Chat::UserChatChannelMembership.count }.from(0)
        end

        it "doesn't automatically join anonymous users" do
          user = Fabricate(:user, trust_level:, last_seen_at:)
          AnonymousUser.create!(user:, master_user: user, active: true)

          expect { job }.not_to change { Chat::UserChatChannelMembership.count }.from(0)
        end

        it "doesn't automatically join users who haven't been seen recently" do
          Fabricate(:user, trust_level:, last_seen_at: 31.days.ago)

          expect { job }.not_to change { Chat::UserChatChannelMembership.count }.from(0)
        end

        it "doesn't automatically join users who aren't in the allowed groups" do
          SiteSetting.chat_allowed_groups = Group::AUTO_GROUPS[:trust_level_3]

          (0..4).each { |tl| Fabricate(:user, trust_level: tl, last_seen_at:) }

          # TL3 + TL4 = 2 users
          expect { job }.to change { Chat::UserChatChannelMembership.count }.from(0).to(2)
        end

        it "limits the number of users who can be auto-joined to SiteSetting.max_chat_auto_joined_users" do
          SiteSetting.max_chat_auto_joined_users = 1

          _user_1 = Fabricate(:user, trust_level:, last_seen_at: 10.days.ago)
          user_2 = Fabricate(:user, trust_level:, last_seen_at: 5.days.ago)

          expect { job }.to change { Chat::UserChatChannelMembership.count }.from(0).to(1)
          expect(Chat::UserChatChannelMembership.last.user).to eq(user_2)
        end

        it "doesn't automatically join users on deleted channels" do
          auto_joinable_public_channel.update!(deleted_at: 1.day.ago)

          Fabricate(:user, trust_level:, last_seen_at:)

          expect { job }.not_to change { Chat::UserChatChannelMembership.count }.from(0)
        end

        it "doesn't automatically join users to channels that have reached the maximum user count" do
          auto_joinable_public_channel.update!(user_count: SiteSetting.max_chat_auto_joined_users)

          Fabricate(:user, trust_level:, last_seen_at:)

          expect { job }.not_to change { Chat::UserChatChannelMembership.count }.from(0)
        end

        it "doesn't create duplicate memberships" do
          user = Fabricate(:user, trust_level:, last_seen_at:)

          Chat::UserChatChannelMembership.create!(user:, chat_channel: auto_joinable_public_channel)

          expect { job }.not_to change { Chat::UserChatChannelMembership.count }.from(1)
        end

        it "doesn't recalculate user count if no users were auto-joined" do
          ::Chat::ChannelMembershipManager.any_instance.expects(:recalculate_user_count).never

          job
        end

        it "doesn't publish new channel if no users were auto-joined" do
          ::Chat::Publisher.expects(:publish_new_channel).never

          job
        end
      end

      context "with a non-auto joinable private channel" do
        fab!(:non_auto_joinable_private_channel) do
          Fabricate(:chat_channel, chatable: private_category)
        end

        it "doesn't automatically join users" do
          user = Fabricate(:user, trust_level:, last_seen_at:)
          private_group_full.add(user)

          expect { job }.not_to change { Chat::UserChatChannelMembership.count }.from(0)
        end
      end

      context "with an auto joinable private channel" do
        fab!(:auto_joinable_private_channel) do
          Fabricate(:chat_channel, chatable: private_category, auto_join_users: true)
        end

        it "automatically join users who have 'full' access to the category" do
          user = Fabricate(:user, trust_level:, last_seen_at:)
          private_group_full.add(user)

          expect { job }.to change { Chat::UserChatChannelMembership.count }.from(0).to(1)
        end

        it "automatically join users who have 'create post' access to the category" do
          user = Fabricate(:user, trust_level:, last_seen_at:)
          private_group_create_post.add(user)

          expect { job }.to change { Chat::UserChatChannelMembership.count }.from(0).to(1)
        end

        it "doesn't automatically join users who have 'readonly' access to the category" do
          user = Fabricate(:user, trust_level:, last_seen_at:)
          private_group_readonly.add(user)

          expect { job }.not_to change { Chat::UserChatChannelMembership.count }.from(0)
        end

        it "doesn't automatically join moderators to an admin-only private channel" do
          private_category_group_full.update!(group_id: Group::AUTO_GROUPS[:admins])

          Fabricate(:moderator, trust_level:, last_seen_at:)
          admin = Fabricate(:admin, trust_level:, last_seen_at:)

          expect { job }.to change { Chat::UserChatChannelMembership.count }.from(0).to(1)
          expect(Chat::UserChatChannelMembership.last.user).to eq(admin)
        end

        it "supports filtering down to a specific private category" do
          another_private_category = Fabricate(:category, read_restricted: true)
          another_private_group = Fabricate(:group)

          Fabricate(
            :category_group,
            category: another_private_category,
            group: another_private_group,
            permission_type: CategoryGroup.permission_types[:full],
          )

          Fabricate(:chat_channel, chatable: another_private_category, auto_join_users: true)

          user = Fabricate(:user, trust_level:, last_seen_at:)
          private_group_full.add(user)
          another_private_group.add(user)

          expect { described_class.call(category_id: private_category.id) }.to change {
            Chat::UserChatChannelMembership.count
          }.from(0).to(1)
        end
      end
    end
  end
end
