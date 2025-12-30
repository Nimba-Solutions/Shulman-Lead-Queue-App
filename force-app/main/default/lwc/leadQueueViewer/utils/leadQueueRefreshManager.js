import { subscribe as empSubscribe, unsubscribe as empUnsubscribe, onError } from 'lightning/empApi';
import { publish, subscribe as lmsSubscribe, unsubscribe as lmsUnsubscribe } from 'lightning/messageService';
import LEAD_QUEUE_REFRESH from '@salesforce/messageChannel/LeadQueueRefresh__c';

export class LeadQueueRefreshManager {
    constructor(component, options = {}) {
        this.component = component;
        this.messageContext = options.messageContext || null;
        this.onRefresh = options.onRefresh || null;
        this.cdcChannel = options.cdcChannel || '/data/litify_pm__Intake__ChangeEvent';
        this.cdcRelevantFields = options.cdcRelevantFields || new Set([
            'litify_pm__Status__c',
            'Priority_Score__c',
            'Queue_Case_Type__c',
            'Case_Type__c',
            'Type__c',
            'Call_at_Date__c',
            'Follow_Up_Date_Time__c',
            'Appointment_Date__c',
            'litify_pm__Sign_Up_Method__c',
            'Qualification_Status__c',
            'Test_Record__c',
            'litify_pm__Display_Name__c',
            'Referred_By_Name__c',
            'litify_pm__Phone__c',
            'Name'
        ]);
        this.empSubscription = null;
        this.lmsSubscription = null;
        this.eventRefreshTimeout = null;
        this.lmsOriginId = options.originId || `${Date.now()}-${Math.random().toString(36).slice(2)}`;
        this.hasRegisteredEmpErrorHandler = false;
    }

    setMessageContext(messageContext) {
        this.messageContext = messageContext;
        if (this.messageContext && !this.lmsSubscription) {
            this.subscribeToMessageChannel();
        }
    }

    connect() {
        this.subscribeToRefreshEvents();
        this.subscribeToMessageChannel();
    }

    disconnect() {
        if (this.eventRefreshTimeout) {
            clearTimeout(this.eventRefreshTimeout);
            this.eventRefreshTimeout = null;
        }
        this.unsubscribeFromRefreshEvents();
        this.unsubscribeFromMessageChannel();
    }

    publish(action) {
        if (!this.messageContext) {
            return;
        }
        publish(this.messageContext, LEAD_QUEUE_REFRESH, {
            action,
            originId: this.lmsOriginId,
            source: 'leadQueueViewer',
            timestamp: Date.now()
        });
    }

    subscribeToRefreshEvents() {
        if (this.empSubscription) {
            return;
        }
        empSubscribe(this.cdcChannel, -1, (message) => {
            this.handleCdcMessage(message);
        }).then((subscription) => {
            this.empSubscription = subscription;
        }).catch((error) => {
            console.error('Failed to subscribe to Lead Queue CDC events:', error);
        });

        if (!this.hasRegisteredEmpErrorHandler) {
            onError((error) => {
                console.error('Lead Queue CDC error:', error);
            });
            this.hasRegisteredEmpErrorHandler = true;
        }
    }

    unsubscribeFromRefreshEvents() {
        if (!this.empSubscription) {
            return;
        }
        empUnsubscribe(this.empSubscription, () => {
            this.empSubscription = null;
        });
    }

    subscribeToMessageChannel() {
        if (this.lmsSubscription || !this.messageContext) {
            return;
        }
        this.lmsSubscription = lmsSubscribe(this.messageContext, LEAD_QUEUE_REFRESH, (payload) => {
            this.handleLmsMessage(payload);
        });
    }

    unsubscribeFromMessageChannel() {
        if (!this.lmsSubscription) {
            return;
        }
        lmsUnsubscribe(this.lmsSubscription);
        this.lmsSubscription = null;
    }

    scheduleEventRefresh() {
        if (this.eventRefreshTimeout) {
            return;
        }
        this.eventRefreshTimeout = setTimeout(() => {
            this.eventRefreshTimeout = null;
            if (typeof this.onRefresh === 'function') {
                this.onRefresh();
            }
        }, 500);
    }

    handleCdcMessage(message) {
        const payload = message?.data?.payload;
        const header = payload?.ChangeEventHeader;
        if (!header) {
            return;
        }
        if (header.changeType && header.changeType !== 'UPDATE') {
            this.scheduleEventRefresh();
            return;
        }
        const changedFields = header.changedFields;
        if (!Array.isArray(changedFields) || changedFields.length === 0) {
            this.scheduleEventRefresh();
            return;
        }
        const hasRelevantChange = changedFields.some((fieldName) => this.cdcRelevantFields.has(fieldName));
        if (hasRelevantChange) {
            this.scheduleEventRefresh();
        }
    }

    handleLmsMessage(payload) {
        if (!payload || payload.originId === this.lmsOriginId) {
            return;
        }
        this.scheduleEventRefresh();
    }
}
